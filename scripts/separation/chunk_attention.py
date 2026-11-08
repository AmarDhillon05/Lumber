# Rewrites every attention block in the htdemucs ONNX graph,
#   S = MatMul(Q, K^T) -> P = Softmax(S, axis=-1) -> O = MatMul(P, V),
# so it runs over slices of query rows and concatenates the results. Softmax is
# per row, so the output is mathematically identical, but the transient
# [1, 8, 2688, 2688] score matrices (231 MB each) shrink by the slice factor.
# That is what pushed a single 7.8 s segment past 2.5 GB of RAM on CPU.
#
#   python scripts/separation/chunk_attention.py in.onnx out.onnx [rows=336]

import sys

import numpy as np
import onnx
from onnx import helper, numpy_helper, shape_inference


def main(src: str, dst: str, rows: int = 336) -> None:
    model = shape_inference.infer_shapes(onnx.load(src))
    g = model.graph
    shape = {vi.name: [d.dim_value for d in vi.type.tensor_type.shape.dim] for vi in g.value_info}
    producer = {o: n for n in g.node for o in n.output}
    consumers: dict[str, list] = {}
    for n in g.node:
        for i in n.input:
            consumers.setdefault(i, []).append(n)

    replace: dict[int, list] = {}  # index of the Softmax node -> new nodes
    drop: set[int] = set()
    index = {id(n): k for k, n in enumerate(g.node)}
    rewritten = 0
    for k, sm in enumerate(g.node):
        if sm.op_type != "Softmax":
            continue
        axis = next((helper.get_attribute_value(a) for a in sm.attribute if a.name == "axis"), -1)
        scores = producer.get(sm.input[0])
        users = consumers.get(sm.output[0], [])
        if axis != -1 or scores is None or scores.op_type != "MatMul" or len(users) != 1 or users[0].op_type != "MatMul":
            continue
        if len(consumers.get(scores.output[0], [])) != 1:
            continue
        out = users[0]
        q, kt = scores.input
        v = out.input[1]
        n_q = shape[q][2]
        if n_q <= rows:
            continue
        sizes = [rows] * (n_q // rows) + ([n_q % rows] if n_q % rows else [])
        tag = f"chunkattn{rewritten}"
        split_name = f"{tag}_sizes"
        g.initializer.append(numpy_helper.from_array(np.array(sizes, dtype=np.int64), split_name))
        q_parts = [f"{tag}_q{i}" for i in range(len(sizes))]
        nodes = [helper.make_node("Split", [q, split_name], q_parts, name=f"{tag}_split", axis=2)]
        o_parts = []
        for i, qi in enumerate(q_parts):
            s, p, o = f"{tag}_s{i}", f"{tag}_p{i}", f"{tag}_o{i}"
            nodes += [
                helper.make_node("MatMul", [qi, kt], [s], name=f"{tag}_qk{i}"),
                helper.make_node("Softmax", [s], [p], name=f"{tag}_softmax{i}", axis=-1),
                helper.make_node("MatMul", [p, v], [o], name=f"{tag}_pv{i}"),
            ]
            o_parts.append(o)
        nodes.append(helper.make_node("Concat", o_parts, list(out.output), name=f"{tag}_concat", axis=2))
        replace[k] = nodes
        drop.update({index[id(scores)], index[id(out)]})
        rewritten += 1

    new_nodes = []
    for k, n in enumerate(g.node):
        if k in drop:
            continue
        new_nodes += replace.get(k, [n])
    del g.node[:]
    g.node.extend(new_nodes)
    # Drop stale shape annotations for removed tensors; ORT re-infers.
    del g.value_info[:]
    onnx.checker.check_model(model)
    onnx.save(model, dst)
    print(f"rewrote {rewritten} attention blocks into {rows}-row slices -> {dst}")


if __name__ == "__main__":
    main(sys.argv[1], sys.argv[2], int(sys.argv[3]) if len(sys.argv) > 3 else 336)
