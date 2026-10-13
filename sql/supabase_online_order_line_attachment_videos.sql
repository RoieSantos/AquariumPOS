-- Online Order line attachments: videos too - per "how about videos can they see it?" / "yes .. make it
-- smaller if possible and viewable".
--
-- The online-order-line-attachments bucket only took images + PDF, max 10 MB. It now also takes
-- MP4 / WebM / MOV video, max 25 MB per file. The portal shrinks a video before uploading it
-- (js/videoCompress.js: max 720p, ~1.2 Mbit/s, MP4 where the browser can record it, else WebM; max
-- 2 minutes), so a typical clip lands well under the limit. Images / PDFs keep their 10 MB limit in
-- the page. MOV is only for the fallback upload of an original iPhone clip when the browser can't
-- compress.
--
-- Run on its own, any time after supabase_online_order_line_attachments.sql. Safe to re-run.
-- Read-only result at the end: the bucket's new settings.

update storage.buckets
set file_size_limit = 26214400, -- 25 MB
    allowed_mime_types = array[
      'image/jpeg', 'image/png', 'image/webp', 'image/gif', 'application/pdf',
      'video/mp4', 'video/webm', 'video/quicktime'
    ]
where id = 'online-order-line-attachments';

select id, file_size_limit, allowed_mime_types
from storage.buckets
where id = 'online-order-line-attachments';
