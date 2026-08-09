// Supabase client + generic upsert helper shared by all portal pages.
// Requires: config.js and the Supabase JS CDN script to be loaded first.
const supabaseClient = window.supabase.createClient(
  window.APP_CONFIG.SUPABASE_URL,
  window.APP_CONFIG.SUPABASE_ANON_KEY
);

/**
 * Insert-or-update a row by checking whether a row matching `matchColumns`
 * already exists, then either updating it or inserting a new one. Mirrors
 * the "check exists, then POST or PATCH" pattern used by the desktop app's
 * Supabase sync code (these tables don't rely on ON CONFLICT upserts).
 *
 * @param {string} table
 * @param {Record<string, any>} matchColumns - columns identifying the row (e.g. { "No.": "TR-123" })
 * @param {Record<string, any>} payload - full set of columns to write (excluding matchColumns, which are merged in automatically on insert)
 * @returns {Promise<'inserted' | 'updated'>}
 */
async function upsertRow(table, matchColumns, payload) {
  // Column names are double-quoted in every .eq() filter below (PostgREST's own quoted-
  // identifier syntax, e.g. "No."=eq.value) because several tables (Transfer_Header/Transfer_Line
  // in particular) have real column names ending in a period ("No.", "Document No.", "Line No.")
  // - PostgREST's query parser otherwise treats a bare "." in a filter key as its embedded-
  // resource separator syntax and fails the whole request with a PGRST100 parse error. Quoting is
  // a no-op for ordinary column names, so this is safe for every existing/future caller.
  let existsQuery = supabaseClient.from(table).select('*', { count: 'exact', head: true });
  for (const [col, val] of Object.entries(matchColumns)) {
    existsQuery = existsQuery.eq(`"${col}"`, val);
  }
  const { count, error: countError } = await existsQuery;
  if (countError) throw countError;

  if (count && count > 0) {
    let updateQuery = supabaseClient.from(table).update(payload);
    for (const [col, val] of Object.entries(matchColumns)) {
      updateQuery = updateQuery.eq(`"${col}"`, val);
    }
    const { error } = await updateQuery;
    if (error) throw error;
    return 'updated';
  }

  const { error } = await supabaseClient.from(table).insert({ ...matchColumns, ...payload });
  if (error) throw error;
  return 'inserted';
}
