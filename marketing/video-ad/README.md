# Video Ad Studio

Makes the 15-second vertical (1080x1920) Facebook/Instagram Reels ad for custom aquariums.

1. Double-click `start-ad-studio.cmd`. It opens the studio in your browser (use Chrome or Edge).
2. Edit text, seconds, or photos in the panel on the right. The preview updates live.
3. Click **Export MP4**. The video is saved to your Downloads folder.

## Use your own photos or videos

- To try one quickly, click **Choose photo/video** on a scene. Click **Use graphic instead** to switch back to the animation.
- To keep it, copy the file into the `media/` folder, click **Copy config**, and paste the result over everything in `ad-config.js`.
- You can also edit `ad-config.js` directly. `media: 'media/shop-tank.mp4'` uses that clip, and `media: null` uses the animation.

Vertical photos and clips look best. Video clips are muted. Add music in the Facebook/Instagram Reels editor, which also avoids copyright problems.
