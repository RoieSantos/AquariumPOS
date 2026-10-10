// Facebook posting defaults (public.FacebookPostSettings, see sql/supabase_facebook_post_settings.sql),
// shared by AI Bot Setup's "Facebook Posts" section and the Facebook Post Test page's
// "Save as Default" button so both read and write the same shape.

// Used until the SQL has been run, or for any column that comes back empty.
const FB_POST_DEFAULTS = {
  captionDirections: '',
  watermarkEnabled: true,
  watermarkStyle: 'center',
  watermarkPosition: 'bottom-right',
  watermarkSize: 60,
  watermarkOpacity: 35,
  watermarkKnockout: true,
  watermarkText: 'RS Pet Stop GMA'
};

async function loadFacebookPostSettings() {
  const { data, error } = await supabaseClient.from('FacebookPostSettings').select('*').eq('"Id"', 1).limit(1);
  const row = !error && data && data[0];
  if (!row) return { ...FB_POST_DEFAULTS };
  return {
    captionDirections: row.CaptionDirections || '',
    watermarkEnabled: row.WatermarkEnabled !== false,
    watermarkStyle: row.WatermarkStyle || FB_POST_DEFAULTS.watermarkStyle,
    watermarkPosition: row.WatermarkPosition || FB_POST_DEFAULTS.watermarkPosition,
    watermarkSize: row.WatermarkSize || FB_POST_DEFAULTS.watermarkSize,
    watermarkOpacity: row.WatermarkOpacity || FB_POST_DEFAULTS.watermarkOpacity,
    watermarkKnockout: row.WatermarkKnockout !== false,
    // null = saved blank on purpose (logo only), so don't fall back to the default text.
    watermarkText: row.WatermarkText || ''
  };
}

// Returns an error message, or null on success.
async function saveFacebookPostSettings(session, settings) {
  const { error } = await supabaseClient.rpc('admin_upsert_facebook_post_settings', {
    p_admin_username: session.username,
    p_admin_password: session.password,
    p_caption_directions: settings.captionDirections || null,
    p_watermark_enabled: settings.watermarkEnabled,
    p_watermark_style: settings.watermarkStyle,
    p_watermark_position: settings.watermarkPosition,
    p_watermark_size: Number(settings.watermarkSize) || FB_POST_DEFAULTS.watermarkSize,
    p_watermark_opacity: Number(settings.watermarkOpacity) || FB_POST_DEFAULTS.watermarkOpacity,
    p_watermark_knockout: settings.watermarkKnockout,
    p_watermark_text: settings.watermarkText || null
  });
  if (!error) return null;
  if (/admin_upsert_facebook_post_settings/.test(error.message)) {
    return 'Run sql/supabase_facebook_post_settings.sql in Supabase first.';
  }
  return error.message;
}
