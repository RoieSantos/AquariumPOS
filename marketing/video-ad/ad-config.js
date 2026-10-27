// RS Pet Stop video ad - edit this file to change the ad.
//
// Each scene shows EITHER an animated graphic ("art") OR your own photo/video ("media"):
//   media: null                    -> uses the animated graphic named in "art"
//   media: 'media/my-photo.jpg'    -> uses that photo instead (slow zoom)
//   media: 'media/my-clip.mp4'     -> uses that video clip instead (muted)
// Put your photos/videos in the media/ folder next to this file.
//
// art options: 'fish' (swimming fish), 'tank-build' (tank draws itself with dimensions),
//              'cta' (logo + call to action), 'none' (just water + text)
//
// Facebook/Instagram Reels cover the top ~250px and bottom ~600px with buttons/captions,
// so keep text short - it is placed in the safe middle area automatically.

window.AD_CONFIG = {
  width: 1080,
  height: 1920,
  fps: 30,
  fileName: 'rspetstop-custom-aquarium-ad.mp4',
  brand: {
    name: 'RS Pet Stop',
    logo: 'media/logo.png'
  },
  scenes: [
    {
      duration: 3.0,
      art: 'fish',
      media: null,
      headline: 'Dream tank?',
      sub: "We'll build it - any size you want."
    },
    {
      duration: 3.2,
      art: 'tank-build',
      media: null,
      headline: 'Made to order',
      sub: 'Your exact length, width & height',
      dims: [48, 18, 20] // inches shown on the animated tank: length, width, height
    },
    {
      duration: 3.0,
      art: 'none',
      media: 'media/aio-on-stand.jpg',
      headline: 'Built your way',
      bullets: ['Rimless or with rim', '3mm-12mm or tempered glass', 'Black or clear sealant']
    },
    {
      duration: 2.6,
      art: 'none',
      media: 'media/stand-black.jpg',
      headline: 'Matching stands & sumps',
      sub: 'Black or white paint, made to fit'
    },
    {
      duration: 3.2,
      art: 'cta',
      media: null,
      headline: 'Get your quote today',
      button: 'rspetstop.com',
      bullets: ['Message us on Facebook', 'or chat with Alice on our website'],
      footer: 'Amaya & GMA branches'
    }
  ]
};
