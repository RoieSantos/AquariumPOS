// Customers page (super users only, same tier as GMA Conversations/AI Bot Sandbox - this data
// carries Messenger PII) - browses public."ChatbotConversations" as the AI bot's CRM record: one
// row per Facebook PSID, with whatever name/phone/address the bot has captured (see
// sql/supabase_chatbot_customer_crm.sql and the save_customer_info tool in
// supabase/functions/_shared/chatbot-engine.ts). Same admin_list_* + renderPaginationBar pattern
// as js/automatedOrders.js.
let currentSession = null;
let customerSearchDebounceHandle = null;
let loadGeneration = 0;
let currentPage = 1;
let currentPageSize = 50;

const NAME_SOURCE_LABEL = {
  CustomerProvided: 'Customer-provided',
  FacebookProfile: 'Facebook profile'
};

function nameSourceBadgeHtml(source) {
  if (!source) return '<span class="muted">-</span>';
  const cls = source === 'CustomerProvided' ? 'badge-success' : 'badge-neutral';
  return `<span class="badge ${cls}">${NAME_SOURCE_LABEL[source] || source}</span>`;
}

function customerRowsHtml(customers) {
  return customers
    .map((c) => `
      <tr>
        <td>${c.customer_name || '<span class="muted">(no name on file)</span>'}</td>
        <td>${nameSourceBadgeHtml(c.customer_name_source)}</td>
        <td>${c.customer_phone || ''}</td>
        <td>${c.customer_address || ''}</td>
        <td>${c.order_count || 0}</td>
        <td>${c.last_message_at_utc ? new Date(c.last_message_at_utc).toLocaleString() : ''}</td>
        <td>${c.created_at_utc ? new Date(c.created_at_utc).toLocaleString() : ''}</td>
      </tr>
    `)
    .join('');
}

async function loadCustomers(search) {
  const myGeneration = ++loadGeneration;
  const tbody = document.getElementById('customerTableBody');
  const trimmedSearch = (search || '').trim();

  const { data, error } = await supabaseClient.rpc('admin_list_gma_customers', {
    p_admin_username: currentSession.username,
    p_admin_password: currentSession.password,
    p_search: trimmedSearch || null,
    p_page: currentPage,
    p_page_size: currentPageSize
  });

  if (myGeneration !== loadGeneration) return;

  if (error) {
    tbody.innerHTML = `<tr><td colspan="7" class="error-text">${error.message}</td></tr>`;
    return;
  }

  tbody.innerHTML = (data || []).length === 0
    ? '<tr><td colspan="7" class="muted">No customers found.</td></tr>'
    : customerRowsHtml(data);

  renderPaginationBar(
    document.getElementById('customerPaginationBar'),
    { page: currentPage, pageSize: currentPageSize, totalCount: data?.[0]?.total_count || 0 },
    {
      onPageChange: (newPage) => { currentPage = newPage; loadCustomers(trimmedSearch); },
      onPageSizeChange: (newSize) => { currentPageSize = newSize; currentPage = 1; loadCustomers(trimmedSearch); }
    }
  );
}

function wireCustomerFilters() {
  const searchInput = document.getElementById('customerSearchInput');
  searchInput.addEventListener('input', () => {
    currentPage = 1;
    clearTimeout(customerSearchDebounceHandle);
    customerSearchDebounceHandle = setTimeout(() => loadCustomers(searchInput.value.trim()), 300);
  });
}

(async function init() {
  const session = await requireAuth();
  if (!session) return;
  currentSession = session;
  renderTopNav('Customers');

  if (!session.isSuperUser) {
    document.getElementById('notAuthorizedBox').classList.remove('hidden');
    return;
  }

  if (!session.password) {
    document.getElementById('unlockBox').classList.remove('hidden');
    document.getElementById('unlockError').textContent = 'Please log out and log back in to view Customers.';
    document.getElementById('unlockBtn').addEventListener('click', logout);
    return;
  }

  document.getElementById('customersContent').classList.remove('hidden');
  wireCustomerFilters();
  await loadCustomers('');
})();
