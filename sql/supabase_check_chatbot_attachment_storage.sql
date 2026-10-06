-- Read-only check: how much the Conversations attachments take in Storage, and whether the 60-day cleanup
-- (cron_cleanup_old_chatbot_messages, supabase_chatbot_message_attachments.sql) is actually removing files.
-- Per "will this balloon the Supabase?" after voice messages / files started being stored too.
--
-- Sections:
--   by type      - stored files per kind (image / video / audio / file / other) with total MB
--   bucket total - every object in the chatbot-attachments bucket, total MB
--   older 60d    - objects older than 60 days (should be ~0 - anything here means cleanup isn't deleting)
--   orphans      - objects no ChatbotMessages row points to (left behind by a failed cleanup)
--   cleanup      - the Vault key the cleanup needs (missing = files are never deleted) + the cron job
--
-- Safe to run any time. ONE result.

with objs as (
  select o.name,
         o.created_at,
         coalesce((o.metadata->>'size')::bigint, 0) as bytes,
         coalesce(o.metadata->>'mimetype', '') as mime
  from storage.objects o
  where o.bucket_id = 'chatbot-attachments'
)
select section, detail, files, round(mb, 1) as mb from (
  select 1 as ord, 'by type' as section,
         case when mime like 'image/%' then 'image' when mime like 'video/%' then 'video'
              when mime like 'audio/%' then 'audio (voice)' when mime = '' then 'unknown' else 'file' end as detail,
         count(*) as files, sum(bytes) / 1048576.0 as mb
    from objs group by 3
  union all
  select 2, 'bucket total', 'chatbot-attachments', count(*), coalesce(sum(bytes), 0) / 1048576.0 from objs
  union all
  select 3, 'older 60d', 'objects older than 60 days (should be ~0)', count(*), coalesce(sum(bytes), 0) / 1048576.0
    from objs where created_at < now() - interval '62 days'
  union all
  select 4, 'orphans', 'objects no message points to', count(*), coalesce(sum(bytes), 0) / 1048576.0
    from objs o
   where not exists (select 1 from public."ChatbotMessages" m where m."AttachmentPath" = o.name)
  union all
  select 5, 'cleanup', 'Vault key supabase_service_role_key present: ' ||
         (exists (select 1 from vault.decrypted_secrets where name = 'supabase_service_role_key'))::text, null, null
  union all
  select 6, 'cleanup', 'cron job: ' || coalesce((select schedule || ' active=' || active::text from cron.job
                                                 where jobname = 'cleanup-old-chatbot-messages'), 'NOT SCHEDULED'), null, null
) r
order by ord, detail;
