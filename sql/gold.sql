CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.vendor_rules` (
  rule_id STRING NOT NULL,
  priority INT64 NOT NULL,
  description_regex STRING NOT NULL,
  vendor_name STRING NOT NULL,
  notes STRING,
  enabled BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.transaction_vendor_overrides` (
  transaction_key STRING NOT NULL,
  vendor_name STRING NOT NULL,
  notes STRING,
  created_at TIMESTAMP NOT NULL
);

CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.vendor_aliases` (
  alias_key STRING NOT NULL,
  alias_name STRING NOT NULL,
  canonical_vendor_name STRING NOT NULL,
  notes STRING,
  enabled BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

MERGE `__PROJECT_ID__.__GOLD_DATASET__.vendor_aliases` AS target
USING UNNEST([
  STRUCT('amazon' AS alias_key, 'Amazon' AS alias_name, 'Amazon' AS canonical_vendor_name),
  STRUCT('amazonmarketplace', 'Amazon Marketplace', 'Amazon'),
  STRUCT('amazoncom', 'Amazon.com', 'Amazon'),
  STRUCT('amzn', 'AMZN', 'Amazon'),
  STRUCT('amznmarketplace', 'AMZN Marketplace', 'Amazon'),
  STRUCT('amaonz', 'Amaonz', 'Amazon')
]) AS seed
ON target.alias_key = seed.alias_key
WHEN NOT MATCHED THEN
  INSERT (alias_key, alias_name, canonical_vendor_name, notes, enabled, created_at)
  VALUES (seed.alias_key, seed.alias_name, seed.canonical_vendor_name, 'Seeded vendor alias', TRUE, CURRENT_TIMESTAMP());

MERGE `__PROJECT_ID__.__GOLD_DATASET__.vendor_rules` AS target
USING UNNEST([
  STRUCT('amazon' AS rule_id, 10 AS priority, r'(?i)\bamazon(?: marketplace|\.com)?\b|amzn\.com' AS description_regex, 'Amazon' AS vendor_name),
  STRUCT('apple-services', 10, r'(?i)apple\.com/bill', 'Apple'),
  STRUCT('cvs', 10, r'(?i)\bcvs', 'CVS'),
  STRUCT('giant-heirloom', 10, r'(?i)giant heirloo', 'Giant Heirloom'),
  STRUCT('new-york-times', 10, r'(?i)\bnytimes(?:\.com)?\b|\bny times\b', 'The New York Times'),
  STRUCT('prime-video', 10, r'(?i)\bprime video\b', 'Prime Video'),
  STRUCT('spotify', 10, r'(?i)\bspotify\b', 'Spotify'),
  STRUCT('starbucks', 10, r'(?i)\bstarbucks\b', 'Starbucks'),
  STRUCT('uber', 10, r'(?i)\buber(?:\b|,|\s|\*)|help\.uber\.com', 'Uber'),
  STRUCT('ultimo-coffee', 10, r'(?i)ultimo coffee', 'Ultimo Coffee'),
  STRUCT('venmo', 10, r'(?i)\bvenmo\b', 'Venmo'),
  STRUCT('allspring-investments', 20, r'(?i)\ballspring\b', 'Allspring Investments'),
  STRUCT('american-airlines', 20, r'(?i)\bamerican airlines\b', 'American Airlines'),
  STRUCT('american-express', 20, r'(?i)\bamerican express\b|\bamex\b', 'American Express'),
  STRUCT('amtrak', 20, r'(?i)\bamtrak\b', 'Amtrak'),
  STRUCT('audible', 20, r'(?i)\baudible\b', 'Audible'),
  STRUCT('bobsled', 20, r'(?i)\bbobsled\b', 'Bobsled'),
  STRUCT('chase', 20, r'(?i)\bchase credit crd\b', 'Chase'),
  STRUCT('credit-card-payment', 90, r'(?i)\bpayment thank you\b|\bautopay payment thank\b', 'Credit Card Payment'),
  STRUCT('disney-plus', 20, r'(?i)\bdisney\s*plus\b', 'Disney+'),
  STRUCT('dunkin', 20, r'(?i)\bdunkin\b', 'Dunkin\''),
  STRUCT('elixr-coffee', 20, r'(?i)\belixr coffee\b', 'Elixr Coffee'),
  STRUCT('fidelity-investments', 20, r'(?i)\bfidelity investments\b', 'Fidelity Investments'),
  STRUCT('google-one', 20, r'(?i)\bgoogle google one\b|\bgoogle one\b', 'Google One'),
  STRUCT('gopuff', 20, r'(?i)\bgo\s*puff\b|\bgopuff\b', 'Gopuff'),
  STRUCT('grubhub', 20, r'(?i)\bgrubhub\b', 'Grubhub'),
  STRUCT('home-depot', 20, r'(?i)\bhome depo', 'The Home Depot'),
  STRUCT('illinois-tollway', 20, r'(?i)\bil tollway\b', 'Illinois Tollway'),
  STRUCT('la-colombe', 20, r'(?i)\bla colombe\b', 'La Colombe'),
  STRUCT('lyft', 20, r'(?i)\blyft\b', 'Lyft'),
  STRUCT('mta', 20, r'(?i)\b(?:mta\s+)?nyct\b', 'MTA'),
  STRUCT('nanit', 20, r'(?i)\bnanit\b', 'Nanit'),
  STRUCT('netflix', 20, r'(?i)\bnetflix\b', 'Netflix'),
  STRUCT('northwestern-medicine', 20, r'(?i)\bnorthwestern my char', 'Northwestern Medicine'),
  STRUCT('openai', 20, r'(?i)\bopenai\b|\bchatgpt\b', 'OpenAI'),
  STRUCT('otter-ai', 20, r'(?i)\botter.?ai', 'Otter.ai'),
  STRUCT('panera-bread', 20, r'(?i)\bpanera bread\b', 'Panera Bread'),
  STRUCT('parkmobile', 20, r'(?i)\bparkmobile|\bpmusa', 'ParkMobile'),
  STRUCT('peco', 20, r'(?i)\bpeco energy\b', 'PECO'),
  STRUCT('peloton', 20, r'(?i)\bpeloton\b', 'Peloton'),
  STRUCT('pgw', 20, r'(?i)\bpgw\b.*\butility\b', 'Philadelphia Gas Works'),
  STRUCT('philadelphia-inquirer', 20, r'(?i)\bphiladelphia inquire', 'The Philadelphia Inquirer'),
  STRUCT('philadelphia-water', 20, r'(?i)\bcityofphila water\b|\bcity of phila.*water\b', 'Philadelphia Water Department'),
  STRUCT('playstation', 20, r'(?i)\bplaystation\b', 'PlayStation'),
  STRUCT('replit', 20, r'(?i)\breplit\b', 'Replit'),
  STRUCT('rival-bros', 20, r'(?i)\brival bros\b', 'Rival Bros Coffee'),
  STRUCT('septa', 20, r'(?i)\bsepta\b', 'SEPTA'),
  STRUCT('south-square-market', 20, r'(?i)\bsouth square(?: market)?\b', 'South Square Market'),
  STRUCT('starz', 20, r'(?i)\bstarz\b', 'Starz'),
  STRUCT('sunoco', 20, r'(?i)\bsunoco\b', 'Sunoco'),
  STRUCT('sweetgreen', 20, r'(?i)\bsweetgreen\b', 'Sweetgreen'),
  STRUCT('target', 20, r'(?i)\btarget\b', 'Target'),
  STRUCT('the-igloo', 20, r'(?i)\bthe igloo\b', 'The Igloo'),
  STRUCT('the-sidecar-bar', 20, r'(?i)\bthe sidecar bar', 'The Sidecar Bar & Grille'),
  STRUCT('verizon', 20, r'(?i)\bverizon\b', 'Verizon'),
  STRUCT('wawa', 20, r'(?i)\bwawa\b', 'Wawa'),
  STRUCT('webflow', 20, r'(?i)\bwebflow\b', 'Webflow'),
  STRUCT('westfield-insurance', 20, r'(?i)\bwestfield(?: ins)? billpay\b', 'Westfield Insurance'),
  STRUCT('whole-foods', 20, r'(?i)\bwholefds\b|\bwhole foods\b', 'Whole Foods Market'),
  STRUCT('wine-and-spirits', 20, r'(?i)\bwine (?:and|&) spiri', 'Fine Wine & Good Spirits'),
  STRUCT('youtube-tv', 20, r'(?i)\byoutube tv\b', 'YouTube TV'),
  STRUCT('7-eleven', 30, r'(?i)\b7[- ]?eleven\b', '7-Eleven'),
  STRUCT('apple-cash', 30, r'(?i)\bapple cash\b', 'Apple Cash'),
  STRUCT('bank-deposit-sweep', 30, r'(?i)\bbank deposit sweep\b', 'Bank Deposit Sweep'),
  STRUCT('bobby-mack-hair', 30, r'(?i)\bbobby mack.*hair\b', 'Bobby Mack & Co. Hair Studio'),
  STRUCT('bon-appetit', 30, r'(?i)\bbonappetit\b|\bbon app[eé]tit\b', 'Bon Appétit'),
  STRUCT('brianette-deli', 30, r'(?i)\bbrianette del', 'Brianette Deli & Grocery'),
  STRUCT('canva', 30, r'(?i)\bcanva\b', 'Canva'),
  STRUCT('cava', 30, r'(?i)\bcava\b', 'CAVA'),
  STRUCT('chop', 30, r'(?i)\bchop physicians\b', 'Children\'s Hospital of Philadelphia'),
  STRUCT('choice-sitter-solutions', 30, r'(?i)\bchoice sitter soluti', 'Choice Sitter Solutions'),
  STRUCT('colonial-savings', 30, r'(?i)\bcolonial savings\b', 'Colonial Savings'),
  STRUCT('di-bruno-bros', 30, r'(?i)\bdi bruno\b', 'Di Bruno Bros.'),
  STRUCT('doordash', 30, r'(?i)\bdoordash\b', 'DoorDash'),
  STRUCT('experian', 30, r'(?i)\bexperian\b', 'Experian'),
  STRUCT('fable', 30, r'(?i)\bfable\b', 'Fable'),
  STRUCT('fubotv', 30, r'(?i)\bfubotv\b', 'FuboTV'),
  STRUCT('investment-purchase', 80, r'(?i)\bbuystock buy purchase of\b', 'Investment Purchase'),
  STRUCT('kids-empire', 30, r'(?i)\bkids empire\b', 'Kids Empire'),
  STRUCT('martial-posture', 30, r'(?i)\bmartial posture\b', 'Martial Posture'),
  STRUCT('newco-public-relations', 30, r'(?i)\bnewco public rel\b', 'Newco Public Relations'),
  STRUCT('orkin', 30, r'(?i)\borkin\b', 'Orkin'),
  STRUCT('philadelphia-parking-authority', 30, r'(?i)\bphiladelphia parking(?: auth|authority)?', 'Philadelphia Parking Authority'),
  STRUCT('pottery-barn-kids', 30, r'(?i)\bpotterybarnkids\b|\bpottery barn kids\b', 'Pottery Barn Kids'),
  STRUCT('schwab-bank', 30, r'(?i)\bschwab bank\b', 'Charles Schwab'),
  STRUCT('soulcycle', 30, r'(?i)\bsoulcycle\b', 'SoulCycle'),
  STRUCT('ventra', 30, r'(?i)\bventra account\b', 'Ventra'),
  STRUCT('vybe-urgent-care', 30, r'(?i)\bvybe urgent care\b', 'vybe urgent care'),
  STRUCT('wall-street-journal', 30, r'(?i)\bwsj\b', 'The Wall Street Journal'),
  STRUCT('zapier', 30, r'(?i)\bzapier\b', 'Zapier')
]) AS seed
ON target.rule_id = seed.rule_id
WHEN MATCHED AND target.notes = 'Seeded deterministic vendor rule' THEN
  UPDATE SET
    priority = seed.priority,
    description_regex = seed.description_regex,
    vendor_name = seed.vendor_name
WHEN NOT MATCHED THEN
  INSERT (rule_id, priority, description_regex, vendor_name, notes, enabled, created_at)
  VALUES (seed.rule_id, seed.priority, seed.description_regex, seed.vendor_name, 'Seeded deterministic vendor rule', TRUE, CURRENT_TIMESTAMP());

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.transactions_base` AS
WITH deduplicated AS (
  SELECT * EXCEPT(deduplication_rank)
  FROM (
    SELECT
      t.*,
      ROW_NUMBER() OVER (
        PARTITION BY transaction_key
        ORDER BY date_added DESC, transaction_date DESC, transaction_id DESC
      ) AS deduplication_rank
    FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_transactions_classified` AS t
  )
  WHERE deduplication_rank = 1
), overrides AS (
  SELECT * EXCEPT(override_rank)
  FROM (
    SELECT
      o.*,
      ROW_NUMBER() OVER (
        PARTITION BY transaction_key
        ORDER BY created_at DESC
      ) AS override_rank
    FROM `__PROJECT_ID__.__GOLD_DATASET__.transaction_vendor_overrides` AS o
  )
  WHERE override_rank = 1
), vendor_rule_matches AS (
  SELECT
    t.transaction_key,
    r.rule_id,
    r.vendor_name,
    ROW_NUMBER() OVER (
      PARTITION BY t.transaction_key
      ORDER BY r.priority, r.rule_id
    ) AS match_rank
  FROM deduplicated AS t
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.vendor_rules` AS r
    ON r.enabled
   AND REGEXP_CONTAINS(COALESCE(t.description, t.full_description, ''), r.description_regex)
), cleaned_base AS (
  SELECT
    t.*,
    o.vendor_name AS override_vendor_name,
    r.vendor_name AS rule_vendor_name,
    r.rule_id AS vendor_rule_id,
    INITCAP(LOWER(NULLIF(TRIM(REGEXP_REPLACE(
      REGEXP_REPLACE(
        REGEXP_REPLACE(
          REGEXP_REPLACE(
            REGEXP_REPLACE(
              UPPER(COALESCE(t.description, t.full_description, '')),
              r'^(APLPAY|APPLE PAY|GOOGLE PAY|SQ \*|TST\*|PAYPAL \*)\s*',
              ''
            ),
            r'\b(?:HTTPS?://|WWW\.)',
            ''
          ),
          r'\.(?:COM|NET|ORG)(?:/[A-Z0-9./_-]*)?',
          ' '
        ),
        r'[#*]?[0-9]{2,}',
        ' '
      ),
      r'[^A-Z0-9&]+',
      ' '
    )), ''))) AS inferred_vendor_name
  FROM deduplicated AS t
  LEFT JOIN overrides AS o USING (transaction_key)
  LEFT JOIN vendor_rule_matches AS r
    ON t.transaction_key = r.transaction_key
   AND r.match_rank = 1
), cleaned AS (
  SELECT
    c.*,
    a.canonical_vendor_name AS alias_vendor_name,
    a.alias_name AS matched_alias_name
  FROM cleaned_base AS c
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.vendor_aliases` AS a
    ON a.enabled
   AND a.alias_key = REGEXP_REPLACE(LOWER(COALESCE(c.inferred_vendor_name, '')), r'[^a-z0-9]+', '')
), vendor_resolved AS (
  SELECT
    *,
    COALESCE(
      override_vendor_name,
      alias_vendor_name,
      rule_vendor_name,
      inferred_vendor_name,
      CONCAT(
        'Unresolved Vendor ',
        SUBSTR(TO_HEX(SHA256(COALESCE(description, full_description, transaction_key))), 1, 8)
      )
    ) AS vendor_name,
    CASE
      WHEN override_vendor_name IS NOT NULL THEN 'override'
      WHEN alias_vendor_name IS NOT NULL THEN CONCAT('alias:', matched_alias_name)
      WHEN rule_vendor_name IS NOT NULL THEN CONCAT('rule:', vendor_rule_id)
      WHEN inferred_vendor_name IS NOT NULL THEN 'normalized_description'
      ELSE 'unresolved'
    END AS vendor_inference_source,
    REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'transfer|credit card payment') AS is_transfer,
    amount > 0 AND REGEXP_CONTAINS(LOWER(COALESCE(category, '')), r'refund|reimbursement|reward') AS is_refund
  FROM cleaned
), category_resolved AS (
  SELECT
    v.*,
    c.category_id,
    c.category_name AS canonical_category,
    c.parent_category,
    c.category_kind
  FROM vendor_resolved AS v
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.category_aliases` AS a
    ON a.active
   AND a.source_system = 'tiller'
   AND COALESCE(a.source_parent_category, '') = ''
   AND REGEXP_REPLACE(LOWER(a.source_category), r'[^a-z0-9]+', '') = REGEXP_REPLACE(LOWER(COALESCE(v.category, '')), r'[^a-z0-9]+', '')
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.categories` AS c
    ON c.active
   AND c.category_id = a.category_id
), epic_resolved AS (
  SELECT
    c.*,
    e.epic_id,
    e.epic_name,
    e.epic_type
  FROM category_resolved AS c
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.epic_transactions` AS e
    ON c.transaction_key = e.transaction_key
   AND e.match_status = 'matched'
)
SELECT
  transaction_key,
  transaction_id,
  transaction_date,
  transaction_month,
  transaction_week,
  EXTRACT(YEAR FROM transaction_date) AS transaction_year,
  EXTRACT(QUARTER FROM transaction_date) AS transaction_quarter,
  description,
  full_description,
  COALESCE(
    inferred_vendor_name,
    CONCAT(
      'Unresolved Vendor ',
      SUBSTR(TO_HEX(SHA256(COALESCE(description, full_description, transaction_key))), 1, 8)
    )
  ) AS observed_vendor_name,
  TO_HEX(SHA256(LOWER(vendor_name))) AS vendor_id,
  vendor_name,
  vendor_inference_source,
  account_id,
  account_name,
  account_number_masked,
  institution,
  amount,
  CASE WHEN amount < 0 AND NOT is_transfer THEN -amount ELSE 0 END AS spend_amount,
  CASE WHEN amount > 0 AND NOT is_transfer AND NOT is_refund THEN amount ELSE 0 END AS income_amount,
  CASE WHEN is_refund THEN amount ELSE 0 END AS refund_amount,
  CASE
    WHEN is_transfer THEN 'transfer'
    WHEN is_refund THEN 'refund'
    WHEN amount < 0 THEN 'expense'
    WHEN amount > 0 THEN 'income'
    ELSE 'zero'
  END AS transaction_type,
  CASE
    WHEN amount < 0 THEN 'outflow'
    WHEN amount > 0 THEN 'inflow'
    ELSE 'neutral'
  END AS cash_flow_direction,
  is_transfer,
  is_refund,
  category,
  category_id,
  canonical_category,
  parent_category,
  category_kind,
  epic_id,
  epic_name,
  epic_type,
  subcategory,
  source_category,
  classification_source,
  categorized_by,
  check_number,
  date_added,
  source
FROM epic_resolved;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.copilot_transaction_matches` AS
WITH raw_copilot AS (
  SELECT
    c.*,
    TO_HEX(SHA256(TO_JSON_STRING(STRUCT(
      transaction_date, name, amount, status, category, parent_category,
      excluded, tags, transaction_type, account_name, account_mask, note,
      recurring
    )))) AS source_fingerprint
  FROM `__PROJECT_ID__.__RAW_DATASET__.copilot_transactions` AS c
), numbered_copilot AS (
  SELECT
    *,
    ROW_NUMBER() OVER (
      PARTITION BY source_fingerprint
      ORDER BY source_fingerprint
    ) AS source_occurrence
  FROM raw_copilot
), typed_copilot AS (
  SELECT
    TO_HEX(SHA256(CONCAT(source_fingerprint, '#', CAST(source_occurrence AS STRING)))) AS source_transaction_key,
    SAFE_CAST(transaction_date AS DATE) AS transaction_date,
    SAFE_CAST(amount AS NUMERIC) AS amount,
    RIGHT(REGEXP_REPLACE(COALESCE(account_mask, ''), r'[^0-9]+', ''), 4) AS account_mask4,
    name,
    category,
    parent_category,
    LOWER(TRIM(transaction_type)) AS transaction_type,
    LOWER(TRIM(excluded)) = 'true' AS excluded
  FROM numbered_copilot
), candidates AS (
  SELECT
    t.transaction_key,
    c.source_transaction_key,
    c.name AS copilot_name,
    c.category AS copilot_category,
    c.parent_category AS copilot_parent_category,
    c.transaction_type AS copilot_transaction_type,
    c.excluded AS copilot_excluded,
    a.category_id AS copilot_category_id,
    COUNT(*) OVER (PARTITION BY t.transaction_key) AS tiller_candidate_count,
    COUNT(*) OVER (PARTITION BY c.source_transaction_key) AS copilot_candidate_count
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions_base` AS t
  JOIN typed_copilot AS c
    ON c.transaction_date = t.transaction_date
   -- Copilot uses positive expenses/negative income; Tiller uses the reverse.
   AND c.amount = -t.amount
   AND c.account_mask4 != ''
   AND c.account_mask4 = RIGHT(REGEXP_REPLACE(COALESCE(t.account_number_masked, ''), r'[^0-9]+', ''), 4)
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.category_aliases` AS a
    ON a.active
   AND a.source_system = 'copilot'
   AND REGEXP_REPLACE(LOWER(COALESCE(a.source_parent_category, '')), r'[^a-z0-9]+', '')
       = REGEXP_REPLACE(LOWER(COALESCE(c.parent_category, '')), r'[^a-z0-9]+', '')
   AND REGEXP_REPLACE(LOWER(a.source_category), r'[^a-z0-9]+', '')
       = REGEXP_REPLACE(LOWER(COALESCE(c.category, '')), r'[^a-z0-9]+', '')
)
SELECT
  transaction_key,
  source_transaction_key AS copilot_transaction_key,
  copilot_name,
  copilot_category,
  copilot_parent_category,
  copilot_category_id,
  copilot_transaction_type,
  copilot_excluded,
  1.00 AS match_confidence
FROM candidates
WHERE tiller_candidate_count = 1
  AND copilot_candidate_count = 1;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.transactions` AS
WITH pair_candidates AS (
  SELECT
    x.transaction_key,
    y.transaction_key AS paired_transaction_key,
    COUNT(*) OVER (PARTITION BY x.transaction_key) AS source_candidate_count,
    COUNT(*) OVER (PARTITION BY y.transaction_key) AS paired_candidate_count
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions_base` AS x
  JOIN `__PROJECT_ID__.__GOLD_DATASET__.transactions_base` AS y
    ON y.transaction_key != x.transaction_key
   AND x.amount != 0
   AND y.amount = -x.amount
   AND COALESCE(y.account_id, y.account_name, '') != COALESCE(x.account_id, x.account_name, '')
   AND ABS(DATE_DIFF(y.transaction_date, x.transaction_date, DAY)) <= 3
  WHERE x.category_kind = 'transfer'
), unique_pairs AS (
  SELECT transaction_key, paired_transaction_key
  FROM pair_candidates
  WHERE source_candidate_count = 1
    AND paired_candidate_count = 1
), evidence AS (
  SELECT
    b.*,
    c.copilot_transaction_key,
    c.copilot_category AS flow_evidence_copilot_category,
    c.copilot_category_id AS flow_evidence_copilot_category_id,
    c.copilot_transaction_type AS flow_evidence_copilot_type,
    c.copilot_excluded AS flow_evidence_copilot_excluded,
    p.paired_transaction_key,
    LOWER(COALESCE(b.description, b.full_description, '')) AS flow_description
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions_base` AS b
  LEFT JOIN `__PROJECT_ID__.__GOLD_DATASET__.copilot_transaction_matches` AS c USING (transaction_key)
  LEFT JOIN unique_pairs AS p USING (transaction_key)
), classified AS (
  SELECT
    e.* EXCEPT(flow_description),
    CASE
      WHEN amount = 0 THEN 'adjustment'
      WHEN flow_evidence_copilot_type = 'regular' AND amount < 0 THEN 'expense'
      WHEN flow_evidence_copilot_type = 'regular' AND amount > 0 THEN 'refund_reimbursement'
      WHEN flow_evidence_copilot_type = 'internal transfer' THEN 'internal_transfer'
      WHEN amount > 0 AND (
        REGEXP_CONTAINS(flow_description, r'dividend|interest payment|sweep interest')
        OR (category_kind = 'income' AND vendor_name IN ('Interest', 'Charles Schwab', 'Dupont De Nemours Inc Dep', 'Omnicom Group Inc Dep'))
      ) THEN 'investment_income'
      WHEN REGEXP_CONTAINS(
        flow_description,
        r'buystock|sellstock|dividend reinvestment|money mkt|money market|bank deposit sweep|vanguard target retirement|investment purchase|mandatory merger|reverse split|split eff|deposit from'
      ) THEN 'investment_activity'
      WHEN flow_evidence_copilot_type = 'income'
       AND (vendor_name IN ('Bobsled', 'Newco Public Relations') OR REGEXP_CONTAINS(flow_description, r'payroll'))
        THEN 'earned_income'
      WHEN flow_evidence_copilot_type = 'income' THEN 'needs_review'
      WHEN category_id = 'paycheck'
       AND (vendor_name IN ('Bobsled', 'Newco Public Relations') OR REGEXP_CONTAINS(flow_description, r'payroll'))
        THEN 'earned_income'
      WHEN category_id = 'paycheck' THEN 'refund_reimbursement'
      WHEN category_id = 'interest_income' AND amount > 0 THEN 'investment_income'
      WHEN category_kind = 'income' AND amount < 0 THEN 'expense'
      WHEN category_kind = 'income' AND amount > 0
       AND REGEXP_CONTAINS(flow_description, r'refund|credit recd|venmo|generation 3|snowflake|boden|target|newco public')
        THEN 'refund_reimbursement'
      WHEN category_kind = 'income' AND amount > 0 THEN 'needs_review'
      WHEN category_kind = 'transfer'
       AND REGEXP_CONTAINS(flow_description, r'payment thank|autopay|online payment|card online payment')
        THEN 'credit_card_payment'
      WHEN category_kind = 'transfer' AND paired_transaction_key IS NOT NULL THEN 'internal_transfer'
      WHEN category_kind = 'transfer' AND REGEXP_CONTAINS(flow_description, r'atm withdraw') THEN 'cash_withdrawal'
      WHEN category_kind = 'transfer' AND amount < 0 THEN 'expense'
      WHEN category_kind = 'transfer' AND amount > 0
       AND NOT REGEXP_CONTAINS(flow_description, r'mobile deposit|remote online deposit|deposit id|check issued|expanded bank deposit|^deposit$')
        THEN 'refund_reimbursement'
      WHEN category_kind = 'transfer' THEN 'needs_review'
      WHEN category_kind = 'expense' AND amount > 0
       AND category_id = 'unclassified'
       AND REGEXP_CONTAINS(flow_description, r'mobile deposit|deposit id|check issued')
        THEN 'needs_review'
      WHEN category_kind = 'expense' AND amount > 0 THEN 'refund_reimbursement'
      WHEN amount < 0 THEN 'expense'
      ELSE 'needs_review'
    END AS flow_type,
    CASE
      WHEN amount = 0 THEN 'zero_amount'
      WHEN flow_evidence_copilot_type = 'regular' THEN 'copilot_regular_direction'
      WHEN flow_evidence_copilot_type = 'internal transfer' THEN 'copilot_internal_transfer'
      WHEN amount > 0 AND (
        REGEXP_CONTAINS(flow_description, r'dividend|interest payment|sweep interest')
        OR (category_kind = 'income' AND vendor_name IN ('Interest', 'Charles Schwab', 'Dupont De Nemours Inc Dep', 'Omnicom Group Inc Dep'))
      ) THEN 'investment_income_description'
      WHEN REGEXP_CONTAINS(
        flow_description,
        r'buystock|sellstock|dividend reinvestment|money mkt|money market|bank deposit sweep|vanguard target retirement|investment purchase|mandatory merger|reverse split|split eff|deposit from'
      ) THEN 'investment_activity_description'
      WHEN vendor_name IN ('Bobsled', 'Newco Public Relations') OR REGEXP_CONTAINS(flow_description, r'payroll')
        THEN 'known_payroll_source'
      WHEN flow_evidence_copilot_type = 'income' THEN 'copilot_income_needs_subtype'
      WHEN category_id = 'paycheck' THEN 'nonpayroll_inflow_in_paycheck_category'
      WHEN category_id = 'interest_income' AND amount > 0 THEN 'interest_category_inflow'
      WHEN category_kind = 'income' AND amount < 0 THEN 'income_category_outflow'
      WHEN category_kind = 'income' AND amount > 0
       AND REGEXP_CONTAINS(flow_description, r'refund|credit recd|venmo|generation 3|snowflake|boden|target|newco public')
        THEN 'refund_or_reimbursement_description'
      WHEN category_kind = 'income' THEN 'income_category_needs_subtype'
      WHEN category_kind = 'transfer'
       AND REGEXP_CONTAINS(flow_description, r'payment thank|autopay|online payment|card online payment')
        THEN 'credit_card_payment_description'
      WHEN category_kind = 'transfer' AND paired_transaction_key IS NOT NULL THEN 'unique_opposite_account_pair'
      WHEN category_kind = 'transfer' AND REGEXP_CONTAINS(flow_description, r'atm withdraw') THEN 'cash_withdrawal_description'
      WHEN category_kind = 'transfer' AND amount < 0 THEN 'unpaired_transfer_outflow'
      WHEN category_kind = 'transfer' AND amount > 0
       AND NOT REGEXP_CONTAINS(flow_description, r'mobile deposit|remote online deposit|deposit id|check issued|expanded bank deposit|^deposit$')
        THEN 'unpaired_person_to_person_inflow'
      WHEN category_kind = 'transfer' THEN 'unpaired_transfer_inflow'
      WHEN category_kind = 'expense' AND amount > 0
       AND category_id = 'unclassified'
       AND REGEXP_CONTAINS(flow_description, r'mobile deposit|deposit id|check issued')
        THEN 'unclassified_deposit_or_check'
      WHEN category_kind = 'expense' AND amount > 0 THEN 'expense_category_inflow'
      WHEN amount < 0 THEN 'outflow_default'
      ELSE 'insufficient_evidence'
    END AS flow_reason,
    CASE
      WHEN amount = 0 THEN 1.00
      WHEN flow_evidence_copilot_type IN ('regular', 'internal transfer') THEN 0.99
      WHEN amount > 0 AND (
        REGEXP_CONTAINS(flow_description, r'dividend|interest payment|sweep interest')
        OR (category_kind = 'income' AND vendor_name IN ('Interest', 'Charles Schwab', 'Dupont De Nemours Inc Dep', 'Omnicom Group Inc Dep'))
      ) THEN 0.98
      WHEN REGEXP_CONTAINS(
        flow_description,
        r'buystock|sellstock|dividend reinvestment|money mkt|money market|bank deposit sweep|vanguard target retirement|investment purchase|mandatory merger|reverse split|split eff|deposit from'
      ) THEN 0.98
      WHEN vendor_name IN ('Bobsled', 'Newco Public Relations') OR REGEXP_CONTAINS(flow_description, r'payroll')
        THEN 0.98
      WHEN category_kind = 'transfer'
       AND REGEXP_CONTAINS(flow_description, r'payment thank|autopay|online payment|card online payment')
        THEN 0.98
      WHEN category_kind = 'transfer' AND paired_transaction_key IS NOT NULL THEN 0.95
      WHEN category_kind = 'transfer' AND amount > 0
       AND NOT REGEXP_CONTAINS(flow_description, r'mobile deposit|remote online deposit|deposit id|check issued|expanded bank deposit|^deposit$')
        THEN 0.80
      WHEN category_kind = 'expense' AND amount < 0 THEN 0.90
      WHEN category_kind = 'expense' AND amount > 0 AND category_id != 'unclassified' THEN 0.90
      WHEN category_id = 'interest_income' AND amount > 0 THEN 0.90
      WHEN category_id = 'paycheck' THEN 0.85
      WHEN category_kind = 'transfer' AND amount < 0 THEN 0.75
      ELSE 0.25
    END AS flow_confidence
  FROM evidence AS e
)
SELECT
  *,
  CASE WHEN flow_type = 'expense' THEN -amount ELSE 0 END AS flow_expense_amount,
  CASE WHEN flow_type IN ('earned_income', 'investment_income') THEN amount ELSE 0 END AS flow_income_amount,
  CASE WHEN flow_type = 'refund_reimbursement' THEN amount ELSE 0 END AS flow_refund_amount,
  CASE WHEN flow_type IN ('internal_transfer', 'credit_card_payment') THEN ABS(amount) ELSE 0 END AS flow_transfer_amount,
  CASE WHEN flow_type = 'investment_activity' THEN ABS(amount) ELSE 0 END AS flow_investment_activity_amount
FROM classified;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.transaction_flow_review` AS
SELECT
  transaction_key,
  transaction_date,
  vendor_name,
  description,
  amount,
  cash_flow_direction,
  category,
  canonical_category,
  category_kind,
  flow_type,
  flow_reason,
  flow_confidence,
  flow_evidence_copilot_type,
  flow_evidence_copilot_category,
  paired_transaction_key,
  account_name,
  institution
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
WHERE flow_type = 'needs_review'
ORDER BY ABS(amount) DESC, transaction_date DESC;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.vendor_canonical_review` AS
SELECT
  observed_vendor_name,
  vendor_name AS canonical_vendor_name,
  vendor_inference_source AS mapping_method,
  CASE
    WHEN vendor_inference_source = 'override' THEN 1.00
    WHEN STARTS_WITH(vendor_inference_source, 'alias:') THEN 0.99
    WHEN STARTS_WITH(vendor_inference_source, 'rule:') THEN 0.95
    WHEN vendor_inference_source = 'normalized_description' THEN 0.50
    ELSE 0.10
  END AS confidence,
  CASE
    WHEN vendor_inference_source = 'override'
      OR STARTS_WITH(vendor_inference_source, 'alias:')
      OR STARTS_WITH(vendor_inference_source, 'rule:')
      THEN 'canonicalized'
    ELSE 'needs_review'
  END AS review_status,
  ARRAY_AGG(DISTINCT canonical_category IGNORE NULLS ORDER BY canonical_category LIMIT 10) AS observed_categories,
  COUNT(*) AS transaction_count,
  ROUND(SUM(spend_amount), 2) AS lifetime_spend,
  MIN(transaction_date) AS first_seen,
  MAX(transaction_date) AS last_seen
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
GROUP BY observed_vendor_name, canonical_vendor_name, mapping_method;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.vendors` AS
WITH category_counts AS (
  SELECT
    vendor_id,
    canonical_category AS category,
    COUNT(*) AS category_transactions
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  WHERE canonical_category IS NOT NULL
    AND NOT is_transfer
  GROUP BY vendor_id, canonical_category
), primary_categories AS (
  SELECT vendor_id, category AS primary_category
  FROM category_counts
  QUALIFY ROW_NUMBER() OVER (
    PARTITION BY vendor_id
    ORDER BY category_transactions DESC, category
  ) = 1
)
SELECT
  t.vendor_id,
  t.vendor_name,
  p.primary_category,
  ARRAY_AGG(DISTINCT t.canonical_category IGNORE NULLS ORDER BY t.canonical_category LIMIT 10) AS observed_categories,
  MIN(t.transaction_date) AS first_transaction_date,
  MAX(t.transaction_date) AS last_transaction_date,
  COUNT(*) AS transaction_count,
  COUNT(DISTINCT t.account_id) AS account_count,
  COUNT(DISTINCT DATE_TRUNC(t.transaction_date, MONTH)) AS active_months,
  ROUND(SUM(t.spend_amount), 2) AS lifetime_spend,
  ROUND(SUM(t.income_amount), 2) AS lifetime_income,
  ROUND(AVG(NULLIF(t.spend_amount, 0)), 2) AS average_purchase,
  LOGICAL_OR(
    STARTS_WITH(t.vendor_inference_source, 'alias:')
    OR STARTS_WITH(t.vendor_inference_source, 'rule:')
    OR t.vendor_inference_source = 'override'
  ) AS has_curated_identity
FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions` AS t
LEFT JOIN primary_categories AS p USING (vendor_id)
GROUP BY t.vendor_id, t.vendor_name, p.primary_category;

CREATE OR REPLACE VIEW `__PROJECT_ID__.__GOLD_DATASET__.accounts` AS
WITH transaction_accounts AS (
  SELECT
    COALESCE(NULLIF(account_id, ''), TO_HEX(SHA256(CONCAT(COALESCE(institution, ''), '|', COALESCE(account_name, ''))))) AS account_key,
    NULLIF(account_id, '') AS account_id,
    ARRAY_AGG(account_name IGNORE NULLS ORDER BY transaction_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS account_name,
    ARRAY_AGG(account_number_masked IGNORE NULLS ORDER BY transaction_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS account_number_masked,
    ARRAY_AGG(institution IGNORE NULLS ORDER BY transaction_date DESC LIMIT 1)[SAFE_OFFSET(0)] AS institution,
    MIN(transaction_date) AS first_transaction_date,
    MAX(transaction_date) AS last_transaction_date,
    COUNT(*) AS transaction_count,
    ROUND(SUM(spend_amount), 2) AS lifetime_spend,
    ROUND(SUM(income_amount), 2) AS lifetime_income
  FROM `__PROJECT_ID__.__GOLD_DATASET__.transactions`
  GROUP BY account_key, account_id
), balance_accounts AS (
  SELECT
    COALESCE(NULLIF(account_id, ''), TO_HEX(SHA256(CONCAT(COALESCE(institution, ''), '|', COALESCE(account_name, ''))))) AS account_key,
    NULLIF(account_id, '') AS account_id,
    account_name,
    account_number_masked,
    institution,
    account_type,
    account_class,
    balance_date,
    balance AS reported_balance,
    signed_balance
  FROM `__PROJECT_ID__.__FINANCE_DATASET__.v_current_balances`
)
SELECT
  COALESCE(b.account_key, t.account_key) AS account_key,
  COALESCE(b.account_id, t.account_id) AS account_id,
  COALESCE(b.account_name, t.account_name) AS account_name,
  COALESCE(b.account_number_masked, t.account_number_masked) AS account_number_masked,
  COALESCE(b.institution, t.institution) AS institution,
  b.account_type,
  b.account_class,
  b.balance_date AS balance_as_of,
  b.reported_balance,
  b.signed_balance,
  t.first_transaction_date,
  t.last_transaction_date,
  COALESCE(t.transaction_count, 0) AS transaction_count,
  COALESCE(t.lifetime_spend, 0) AS lifetime_spend,
  COALESCE(t.lifetime_income, 0) AS lifetime_income,
  b.account_key IS NOT NULL AS has_balance_history,
  t.account_key IS NOT NULL AS has_transactions
FROM balance_accounts AS b
FULL OUTER JOIN transaction_accounts AS t USING (account_key);
