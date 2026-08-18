-- One-off diagnostic (run against the LOCAL SQL Server database, not Supabase) - checks whether
-- Conversation_ID is stable per customer across their separate orders, or whether it changes
-- order-to-order. If a repeat customer shows the SAME Conversation_ID on every one of their
-- orders, it's safe to treat as a fixed per-customer identifier (e.g. for sending them a message
-- without needing to look it up per-order). If it varies, it's NOT safe to cache/reuse.

SELECT
    CustomerName,
    Page_ID,
    Conversation_ID,
    COUNT(*) AS OrderCount,
    MIN(OrderID) AS FirstOrderID,
    MAX(OrderID) AS LastOrderID
FROM dbo.OnlineOrderHeader
WHERE Conversation_ID IS NOT NULL AND Conversation_ID <> ''
GROUP BY CustomerName, Page_ID, Conversation_ID
ORDER BY CustomerName;

-- Read this as: if the SAME CustomerName appears on multiple rows with DIFFERENT
-- Conversation_ID values, that customer's conversation ID is NOT stable across orders.
-- If every CustomerName maps to exactly one Conversation_ID no matter how many orders they
-- have, it IS stable - safe to key messages/order-tagging off it.
SELECT
    CustomerName,
    Page_ID,
    COUNT(DISTINCT Conversation_ID) AS DistinctConversationIds,
    COUNT(*) AS TotalOrders
FROM dbo.OnlineOrderHeader
WHERE Conversation_ID IS NOT NULL AND Conversation_ID <> ''
GROUP BY CustomerName, Page_ID
HAVING COUNT(*) > 1
ORDER BY DistinctConversationIds DESC, TotalOrders DESC;
