-- Facebook posting defaults, editable from AI Bot Setup ("Facebook Posts" section) and saved
-- from the Facebook Post Test page's "Save as Default" button, so staff don't re-enter them on
-- every post. Single row, same shape as ChatbotFollowUpSettings.
--
--   CaptionDirections - standing instructions for the AI caption writer (tone, contact number,
--                       delivery info, hashtags...). Read by supabase/functions/facebook-page-post
--                       on every caption, on top of its built-in rules. The page's per-post
--                       notes box is for one-off facts (this item's price, this week's promo).
--   Watermark*        - the watermark controls on docs/facebook-post-test.html, loaded as the
--                       starting values each time the page opens.
--
-- Safe to re-run.

create table if not exists public."FacebookPostSettings" (
    "Id" smallint primary key default 1 check ("Id" = 1),
    "CaptionDirections" text,
    "WatermarkEnabled" boolean not null default true,
    "WatermarkStyle" varchar(20) not null default 'center',
    "WatermarkPosition" varchar(20) not null default 'bottom-right',
    "WatermarkSize" int not null default 60,
    "WatermarkOpacity" int not null default 35,
    "WatermarkKnockout" boolean not null default true,
    "WatermarkText" varchar(100) default 'RS Pet Stop GMA',
    "UpdatedBy" varchar(100),
    "UpdatedAtUtc" timestamptz not null default now()
);

insert into public."FacebookPostSettings" ("Id") values (1) on conflict ("Id") do nothing;

alter table public."FacebookPostSettings" enable row level security;

drop policy if exists "Public read" on public."FacebookPostSettings";
create policy "Public read" on public."FacebookPostSettings"
    for select to anon, authenticated using (true);

-- Writes only via the RPC below.
revoke insert, update, delete on public."FacebookPostSettings" from anon, authenticated;

comment on table public."FacebookPostSettings" is 'Single-row Facebook posting defaults (AI caption directions + watermark) - publicly readable, edited only via admin_upsert_facebook_post_settings.';

create or replace function public.admin_upsert_facebook_post_settings(
  p_admin_username text,
  p_admin_password text,
  p_caption_directions text,
  p_watermark_enabled boolean,
  p_watermark_style text,
  p_watermark_position text,
  p_watermark_size int,
  p_watermark_opacity int,
  p_watermark_knockout boolean,
  p_watermark_text text
)
returns void
language plpgsql
security definer
set search_path = public, extensions
as $$
begin
  if not public.is_admin_authorized(p_admin_username, p_admin_password) then
    raise exception 'Not authorized.';
  end if;

  insert into public."FacebookPostSettings"
    ("Id", "CaptionDirections", "WatermarkEnabled", "WatermarkStyle", "WatermarkPosition",
     "WatermarkSize", "WatermarkOpacity", "WatermarkKnockout", "WatermarkText", "UpdatedBy", "UpdatedAtUtc")
  values
    (1, nullif(trim(p_caption_directions), ''), coalesce(p_watermark_enabled, true),
     case when p_watermark_style in ('center', 'tiled', 'badge') then p_watermark_style else 'center' end,
     case when p_watermark_position in ('bottom-right', 'bottom-left', 'top-right', 'top-left') then p_watermark_position else 'bottom-right' end,
     least(greatest(coalesce(p_watermark_size, 60), 20), 90),
     least(greatest(coalesce(p_watermark_opacity, 35), 10), 80),
     coalesce(p_watermark_knockout, true), nullif(trim(p_watermark_text), ''),
     p_admin_username, now())
  on conflict ("Id") do update set
    "CaptionDirections" = excluded."CaptionDirections",
    "WatermarkEnabled" = excluded."WatermarkEnabled",
    "WatermarkStyle" = excluded."WatermarkStyle",
    "WatermarkPosition" = excluded."WatermarkPosition",
    "WatermarkSize" = excluded."WatermarkSize",
    "WatermarkOpacity" = excluded."WatermarkOpacity",
    "WatermarkKnockout" = excluded."WatermarkKnockout",
    "WatermarkText" = excluded."WatermarkText",
    "UpdatedBy" = excluded."UpdatedBy",
    "UpdatedAtUtc" = excluded."UpdatedAtUtc";
end;
$$;

grant execute on function public.admin_upsert_facebook_post_settings(text, text, text, boolean, text, text, int, int, boolean, text) to anon;
