// Switchboard for song-source APIs another branch is delivering. The app
// imports these names from here only; when the real modules land on main,
// re-export them below instead and delete the shim files.
//
//   localFile.ts → src/sources/localFile.ts  (importLocalFile)
//   youtube.ts   → src/sources/youtube.ts    (youtubeSource)

export { importLocalFile } from './localFile';
export { youtubeSource } from './youtube';
