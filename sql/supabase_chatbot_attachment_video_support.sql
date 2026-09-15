-- Lets staff attach a VIDEO (not just a photo) via the paperclip icon in GMA Conversations' reply
-- composer (supabase_chatbot_staff_attachment_upload.sql) - per direct follow-up report, uploading
-- an .mp4 failed with "mime type video/mp4 is not supported", since the chatbot-attachments bucket
-- (supabase_chatbot_message_attachments.sql) was created image-only.
--
-- The bucket already exists, so this UPDATEs it rather than re-inserting (the original file's
-- `on conflict do nothing` insert would silently no-op against an existing row, not change its
-- settings). Also raises the 10MB image-era file_size_limit to 25MB - Facebook's own documented cap
-- for a Send API attachment delivered by URL (not resumable upload), which a real video clip can
-- realistically approach even where a photo never would.
update storage.buckets
set allowed_mime_types = array['image/jpeg', 'image/png', 'image/webp', 'image/gif', 'video/mp4', 'video/quicktime'],
    file_size_limit = 26214400
where id = 'chatbot-attachments';
