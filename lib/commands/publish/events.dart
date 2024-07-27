

// export const produceEvents = async (app, release, fileMetadatas, nsec) => {
//   let pubkey;
//   if (nsec) {
//     pubkey = getPublicKey(nsec);
//   } else if (app.npub?.trim()) {
//     pubkey = decode(app.npub.trim()).data;
//   } else {
//     throw `No nsec and no npub`;
//   }
//   // TODO: Warn if nsec-derived npub does not match supplied npub in file

//   // 0

//   // TODO check for kind 0, does it have x509 from APK?
//   // if not, generate new kind 0 ready to be signed

//   // 32267

//   const platforms = [...new Set(fileMetadatas.map(m => m.platforms).flat())];
//   console.log('found these', platforms);

//   const partialAppEvent = {
//     kind: 32267,
//     content: app.description ?? app.summary,
//     created_at: Math.floor(Date.now() / 1000),
//     tags: [
//       ['d', app.identifier],
//       ['name', app.name],
//       ...(app.repository ? [['repository', app.repository]] : []),
//       // TODO RESTORE
//       // ...(iconHashName ? [['icon', `https://cdn.zap.store/${iconHashName}`]] : []),
//       // ...(imageHashNames.map(i => ['image', `https://cdn.zap.store/${i}`])),
//       ...(app.homepage ? [['url', app.homepage]] : []),
//       ...(pubkey ? [['p', pubkey], ['zap', pubkey, '1']] : []),
//       ...app.tags,
//       ...(app.license ? [['license', app.license]] : []),
//       ...(platforms.map(f => ['f', f])),
//     ]
//   };

//   const appEvent = nsec ? finalizeEvent(partialAppEvent, nsec) : partialAppEvent;

//   // 1063

//   const fileMetadataEvents = [];

//   for (const fm of fileMetadatas) {
//     const partialMetadataEvent = {
//       kind: 1063,
//       content: `${app.name} ${fm.version || release.tagName}`,
//       created_at: Date.parse(release.createdAt) / 1000,
//       tags: [
//         ['url', fm.url],
//         ['m', fm.contentType],
//         ['x', fm.hash],
//         ['size', fm.size],
//         ...(fm.version ? [['version', fm.version]] : []),
//         ...(fm.versionCode ? [['version_code', fm.versionCode]] : []),
//         ...(fm.minSdkVersion ? [['min_sdk_version', fm.minSdkVersion]] : []),
//         ...(fm.targetSdkVersion ? [['target_sdk_version', fm.targetSdkVersion]] : []),
//         ...(fm.signatureHashes ?? []).map(h => ['apk_signature_hash', h]),
//         ...(fm.platforms ?? []).map(f => ['f', f]),
//         ...(app.repository ? [['repository', app.repository]] : []),
//         // TODO RESTORE
//         // ...(iconHashName ? [['image', `https://cdn.zap.store/${iconHashName}`]] : []),
//         ...(pubkey ? [['p', pubkey], ['zap', pubkey, '1']] : [])
//       ]
//     };

//     fileMetadataEvents.push(nsec ? finalizeEvent(partialMetadataEvent, nsec) : partialMetadataEvent);
//   }

//   // 30063

//   const partialReleaseEvent = {
//     kind: 30063,
//     content: release.text,
//     created_at: Date.parse(release.createdAt) / 1000,
//     tags: [
//       ['d', `${app.identifier}@${release.tagName}`],
//       ['url', release.url],
//       ...fileMetadataEvents.map(e => ['e', e.id]),
//       ['a', `${appEvent.kind}:${appEvent.pubkey}:${app.identifier}`],
//     ]
//   };

//   const releaseEvent = nsec ? finalizeEvent(partialReleaseEvent, nsec) : partialReleaseEvent;

//   return {
//     appEvent,
//     releaseEvent,
//     fileMetadataEvents,
//   };
// };