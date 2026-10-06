-- Conversations: keep customers' voice messages and files (per "make attachments / link readable on the
-- conversations") - facebook-messenger-webhook now downloads audio + file attachments into the private
-- chatbot-attachments bucket too (it used to keep only photos/videos and write "[Voice message]" / "[File]"),
-- so staff can play / open them in the thread. The bucket was image/video-only, so this widens its
-- allowed types. Same 25MB limit, same 60-day cleanup (cron deletes by AttachmentPath, any type).
--
-- application/octet-stream is included because Facebook's CDN often labels files that way and the
-- webhook can't map every extension - the bucket is private (signed URLs, staff only).
--
-- Run AFTER supabase_chatbot_attachment_video_support.sql. Safe to re-run.
-- Ends with ONE result: the bucket's settings.

update storage.buckets
set allowed_mime_types = array[
      'image/jpeg', 'image/png', 'image/webp', 'image/gif',
      'video/mp4', 'video/quicktime',
      'audio/mpeg', 'audio/mp4', 'audio/aac', 'audio/wav', 'audio/x-wav', 'audio/ogg', 'audio/webm', 'audio/x-m4a',
      'application/pdf', 'application/msword',
      'application/vnd.openxmlformats-officedocument.wordprocessingml.document',
      'application/vnd.ms-excel',
      'application/vnd.openxmlformats-officedocument.spreadsheetml.sheet',
      'application/vnd.ms-powerpoint',
      'application/vnd.openxmlformats-officedocument.presentationml.presentation',
      'text/plain', 'text/csv', 'application/zip', 'application/octet-stream'
    ],
    file_size_limit = 26214400
where id = 'chatbot-attachments';

comment on column public."ChatbotMessages"."AttachmentType" is
  'Facebook attachment type of the stored file: image, video, audio (voice message) or file. Null when nothing was stored (location / shared link rows carry their link in Content).';

select id, public, file_size_limit, allowed_mime_types
  from storage.buckets
 where id = 'chatbot-attachments';
