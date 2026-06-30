-- 1. DATA CLEANING

-- Remove nulls and invalid values
SELECT
  CAST(Customer_ID AS STRING) AS Customer_ID,
FROM `ringed-robot-471523-i4.Assignment2.Customer`;

#Create cleaned transactions table
CREATE OR REPLACE TABLE `ringed-robot-471523-i4.Assignment2.Transaction_cleaned` AS
SELECT *
FROM `ringed-robot-471523-i4.Assignment2.Transaction`
WHERE Customer_ID IS NOT NULL
  AND Transaction_ID IS NOT NULL
  AND Transaction_Date IS NOT NULL
  AND Quantity > 0
  AND Avg_Price > 0
  AND Discount_pct BETWEEN 0 AND 100;

  # Clean Customer data
  CREATE OR REPLACE TABLE `ringed-robot-471523-i4.Assignment2.Customercleaned` AS
SELECT *
FROM `ringed-robot-471523-i4.Assignment2.Customer`
WHERE Customer_ID IS NOT NULL;

#Outlier checks – transactions
SELECT
  APPROX_QUANTILES(Quantity, 100)        AS qty_q,
  APPROX_QUANTILES(Avg_Price, 100)       AS price_q,
  APPROX_QUANTILES(Delivery_Charges, 100) AS delivery_q,
  APPROX_QUANTILES(Discount_pct, 100)    AS discount_q
FROM `ringed-robot-471523-i4.Assignment2.Transaction_cleaned`;

#Outlier checks for Customer
SELECT
  APPROX_QUANTILES(Tenure_Months, 100)        AS tenure_q,
  APPROX_QUANTILES(Chatbot_Usage_Count, 100)  AS chatbot_q,
  APPROX_QUANTILES(Email_Opened_Count, 100)   AS email_q,
  APPROX_QUANTILES(Clicked_Ad_Campaigns, 100) AS ad_clicks_q
FROM `ringed-robot-471523-i4.Assignment2.Customers_cleaned`;


--Core KPIs by loyalty (orders, total spend, AOV, per-customer views)
WITH per_order AS (
  SELECT
    c.Loyalty_Program_Status AS loyalty,
    t.Customer_ID,
    t.Transaction_ID,
    (t.Quantity * t.Avg_Price) * (1 - IFNULL(t.Discount_pct,0)/100.0)
      + IFNULL(t.Delivery_Charges,0) AS total_paid
  FROM `ringed-robot-471523-i4.Assignment2.Transaction_cleaned` t
  JOIN `ringed-robot-471523-i4.Assignment2.Customer_cleaned`    c USING (Customer_ID)
)
SELECT
  loyalty,
  COUNT(DISTINCT Customer_ID)                                   AS customers,
  COUNT(DISTINCT Transaction_ID)                                AS orders,
  SUM(total_paid)                                               AS total_spend,
  SAFE_DIVIDE(SUM(total_paid), NULLIF(COUNT(DISTINCT Transaction_ID),0)) AS avg_order_value,
  SAFE_DIVIDE(COUNT(DISTINCT Transaction_ID), NULLIF(COUNT(DISTINCT Customer_ID),0)) AS orders_per_customer,
  SAFE_DIVIDE(SUM(total_paid), NULLIF(COUNT(DISTINCT Customer_ID),0))               AS spend_per_customer
FROM per_order
GROUP BY loyalty
ORDER BY total_spend DESC;

-- Coupon usage rate and average discount%
SELECT
  c.Loyalty_Program_Status AS loyalty,
  SAFE_DIVIDE(SUM(CASE WHEN t.Coupon_Status = 'Used' THEN 1 ELSE 0 END),
              NULLIF(COUNT(DISTINCT t.Transaction_ID),0))       AS pct_orders_with_coupon,
  AVG(IFNULL(t.Discount_pct,0))                                  AS avg_discount_pct_on_orders
  FROM `ringed-robot-471523-i4.Assignment2.Transaction_cleaned` t
  JOIN `ringed-robot-471523-i4.Assignment2.Customer_cleaned`    c USING (Customer_ID)
GROUP BY loyalty
ORDER BY pct_orders_with_coupon DESC;

-- Engagement by loyalty (customer-level averages)
SELECT
  Loyalty_Program_Status AS loyalty,
  AVG(Chatbot_Usage_Count)    AS avg_chatbot_use,
  AVG(Email_Opened_Count)     AS avg_email_opens,
  AVG(Clicked_Ad_Campaigns)   AS avg_ad_clicks
FROM `ringed-robot-471523-i4.Assignment2.Customer_cleaned`
GROUP BY loyalty
ORDER BY avg_email_opens DESC;
-- Median AOV using quantiles (robust to outliers)
WITH per_order AS (
  SELECT
    c.Loyalty_Program_Status AS loyalty,
    t.Transaction_ID,
    (t.Quantity * t.Avg_Price) * (1 - IFNULL(t.Discount_pct,0)/100.0)
      + IFNULL(t.Delivery_Charges,0) AS total_paid
FROM `ringed-robot-471523-i4.Assignment2.Transaction_cleaned` t
  JOIN `ringed-robot-471523-i4.Assignment2.Customer_cleaned`    c USING (Customer_ID)
),
q AS (
  SELECT
    loyalty,
    APPROX_QUANTILES(total_paid, 101)[OFFSET(50)] AS median_aov
  FROM per_order
  GROUP BY loyalty
)
SELECT * FROM q ORDER BY median_aov DESC;
--  Calculate Recency, Frequency, Monetary and assign scores
CREATE OR REPLACE TABLE `ringed-robot-471523-i4.Assignment2.rfm_segments` AS
WITH base AS (
  SELECT
    Customer_ID,
    DATE(Transaction_Date) AS txn_date,
    (Quantity * Avg_Price) * (1 - IFNULL(Discount_pct,0)/100.0)
      + IFNULL(Delivery_Charges,0) AS total_paid
  FROM `ringed-robot-471523-i4.Assignment2.Transaction_cleaned`
),
agg AS (
  SELECT
    Customer_ID,
    DATE_DIFF(CURRENT_DATE(), MAX(txn_date), DAY) AS recency_days,
    COUNT(*)                                       AS frequency,
    SUM(total_paid)                                AS monetary
  FROM base
  GROUP BY Customer_ID
)
SELECT
  *,
  NTILE(5) OVER (ORDER BY recency_days ASC) AS R_score,
  NTILE(5) OVER (ORDER BY frequency DESC)   AS F_score,
  NTILE(5) OVER (ORDER BY monetary  DESC)   AS M_score
FROM agg;
-- Compare engagement and spend by tenure stage and gender
WITH tenure AS (
  SELECT
    c.Customer_ID,
    c.Gender,
    CASE
      WHEN c.Tenure_Months < 12 THEN 'New (<1 yr)'
      WHEN c.Tenure_Months BETWEEN 12 AND 36 THEN 'Established (1-3 yrs)'
      ELSE 'Loyal (3+ yrs)'
    END AS tenure_group,
    c.Chatbot_Usage_Count, c.Email_Opened_Count, c.Clicked_Ad_Campaigns
  FROM `ringed-robot-471523-i4.Assignment2.Customer_cleaned` c
),
spend AS (
  SELECT
    Customer_ID,
    COUNT(DISTINCT Transaction_ID) AS orders,
    SUM( (Quantity * Avg_Price) * (1 - IFNULL(Discount_pct,0)/100.0)
        + IFNULL(Delivery_Charges,0) ) AS total_spend
  FROM `ringed-robot-471523-i4.Assignment2.Transaction_cleaned`
  GROUP BY Customer_ID
)
SELECT
  t.Gender,
  t.tenure_group,
  COUNT(*)                   AS customers,
  AVG(s.orders)              AS avg_orders,
  AVG(s.total_spend)         AS avg_spend,
  AVG(t.Chatbot_Usage_Count) AS avg_chatbot,
  AVG(t.Email_Opened_Count)  AS avg_email_opens,
  AVG(t.Clicked_Ad_Campaigns) AS avg_ad_clicks
FROM tenure t
LEFT JOIN spend s USING (Customer_ID)
GROUP BY t.Gender, t.tenure_group
ORDER BY t.Gender, t.tenure_group;
-- Summarise customers by RFM segment
WITH scored AS (
  SELECT
    Customer_ID,
    (R_score + F_score + M_score) AS RFM_score,
    recency_days, frequency, monetary
  FROM `ringed-robot-471523-i4.Assignment2.rfm_segments`
),
band AS (
  SELECT
    *,
    CASE
      WHEN RFM_score >= 12 THEN 'High Value'
      WHEN RFM_score BETWEEN 7 AND 11 THEN 'Mid Value'
      ELSE 'Low Value'
    END AS rfm_segment
  FROM scored
)
SELECT
  b.rfm_segment,
  COUNT(*)          AS customers,
  AVG(recency_days) AS avg_recency,
  AVG(frequency)    AS avg_frequency,
  AVG(monetary)     AS avg_monetary
FROM band b
GROUP BY b.rfm_segment
ORDER BY customers DESC;
--Engagement and channel by RFM segment
WITH band AS (
  SELECT
    Customer_ID,
    CASE
      WHEN (R_score + F_score + M_score) >= 12 THEN 'High Value'
      WHEN (R_score + F_score + M_score) BETWEEN 7 AND 11 THEN 'Mid Value'
      ELSE 'Low Value'
    END AS rfm_segment
  FROM `ringed-robot-471523-i4.Assignment2.rfm_segments`
)
SELECT
  b.rfm_segment,
  c.Preferred_Channel,
  COUNT(*)                    AS customers,
  AVG(c.Email_Opened_Count)   AS avg_email_opens,
  AVG(c.Clicked_Ad_Campaigns) AS avg_ad_clicks,
  AVG(c.Chatbot_Usage_Count)  AS avg_chatbot
FROM band b
JOIN `ringed-robot-471523-i4.Assignment2.Customer_cleaned` c USING (Customer_ID)
GROUP BY b.rfm_segment, c.Preferred_Channel
ORDER BY b.rfm_segment, customers DESC;

