# Builds a parity fixture for tests/separation.parity.ts: a synthetic 20 s
# drum + music mix and the PyTorch demucs htdemucs stems for it (shifts=0).
#   pip install torch demucs soundfile numpy
#   python scripts/separation/make_reference.py <out_dir>
import numpy as np, soundfile as sf, torch, sys
from demucs.pretrained import get_model
from demucs.apply import apply_model
out = sys.argv[1]; sr = 44100; dur = 20.0; n = int(sr*dur)
rng = np.random.default_rng(0); t = np.arange(n)/sr
bpm = 100; beat = 60/bpm
drums = np.zeros((2, n)); music = np.zeros((2, n))
def env(k, tau): return np.exp(-np.arange(k)/sr/tau)
for b in range(int(dur/beat)):
    s = int(b*beat*sr)
    if b % 2 == 0:  # kick
        k = int(0.4*sr); tt = np.arange(k)/sr
        f = 50 + 100*np.exp(-tt/0.03); x = np.sin(2*np.pi*np.cumsum(f)/sr)*env(k, 0.12)
        drums[:, s:s+k] += 0.9*x[:n-s]
    else:  # snare
        k = int(0.25*sr); x = (rng.standard_normal(k)*0.6 + np.sin(2*np.pi*190*np.arange(k)/sr))*env(k, 0.06)
        drums[:, s:s+k] += 0.6*x[:n-s]
    for h in range(2):  # hats
        hs = s + int(h*beat/2*sr); k = int(0.05*sr)
        x = np.diff(rng.standard_normal(k+1))*env(k, 0.015)
        drums[0, hs:hs+k] += 0.25*x[:max(0, n-hs)]; drums[1, hs:hs+k] += 0.2*x[:max(0, n-hs)]
chords = [[220, 277.2, 329.6], [196, 246.9, 293.7], [174.6, 220, 261.6], [196, 246.9, 293.7]]
for i, c in enumerate(chords*3):
    s = int(i*4*beat*sr)
    if s >= n: break
    e = min(n, int((i+1)*4*beat*sr)); tt = t[s:e]-t[s]
    for f in c:
        music[0, s:e] += 0.08*np.sin(2*np.pi*f*tt); music[1, s:e] += 0.08*np.sin(2*np.pi*f*1.003*tt)
    music[:, s:e] += 0.25*np.sin(2*np.pi*c[0]/4*tt)  # bass
mix = (drums + music).astype(np.float32)
sf.write(f'{out}/mix.wav', mix.T, sr, subtype='FLOAT')
sf.write(f'{out}/true_drums.wav', drums.T.astype(np.float32), sr, subtype='FLOAT')
model = get_model('htdemucs'); model.eval()
wav = torch.from_numpy(mix)
ref = wav.mean(0); wav = (wav - ref.mean()) / ref.std()
with torch.no_grad():
    stems = apply_model(model, wav[None], shifts=0, split=True, overlap=0.25, progress=False)[0]
stems = stems * ref.std() + ref.mean()
print(model.sources if hasattr(model, 'sources') else '', stems.shape)
stems.numpy().astype(np.float32).tofile(f'{out}/ref_stems.f32')  # (4 sources, 2, n)
