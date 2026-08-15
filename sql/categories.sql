CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.categories` (
  category_id STRING NOT NULL,
  category_name STRING NOT NULL,
  parent_category STRING NOT NULL,
  category_kind STRING NOT NULL,
  description STRING,
  active BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL,
  -- Orthogonal cost attributes. A category answers "what did I buy"; these answer
  -- "how does it behave", which is what the cash-flow analyses actually slice on.
  -- cost_behavior: fixed (obligation, same every month) | committed (recurring but
  --   cancellable) | variable (flexes with behaviour). Drives the three-tier nut.
  -- essential: could this stop within 30 days without material harm? Drives stress tests.
  cost_behavior STRING,
  essential BOOL
);

ALTER TABLE `__PROJECT_ID__.__GOLD_DATASET__.categories` ADD COLUMN IF NOT EXISTS cost_behavior STRING;
ALTER TABLE `__PROJECT_ID__.__GOLD_DATASET__.categories` ADD COLUMN IF NOT EXISTS essential BOOL;
-- cadence was the wrong grain: a category has no billing cadence, a charge does.
-- Spreading is now explicit only (gold.amortization_schedule).
ALTER TABLE `__PROJECT_ID__.__GOLD_DATASET__.categories` DROP COLUMN IF EXISTS cadence;

MERGE `__PROJECT_ID__.__GOLD_DATASET__.categories` AS target
USING UNNEST([
  STRUCT('coffee' AS category_id, 'Coffee' AS category_name, 'Food & Drink' AS parent_category, 'expense' AS category_kind, 'Coffee shops and coffee purchases' AS description, TRUE AS is_active, 'variable' AS cost_behavior, FALSE AS essential),
  STRUCT('delivery', 'Delivery', 'Food & Drink', 'expense', 'Prepared-food delivery (Uber Eats, DoorDash, Gopuff)', TRUE, 'variable', FALSE),
  STRUCT('groceries', 'Groceries', 'Food & Drink', 'expense', 'Groceries, household food, and retail alcohol', TRUE, 'variable', TRUE),
  STRUCT('restaurants_bars', 'Restaurants & Bars', 'Food & Drink', 'expense', 'Restaurants, bars, and dining out', TRUE, 'variable', FALSE),
  STRUCT('clothes_grooming', 'Clothes & Grooming', 'Home, Health & Clothes', 'expense', 'Clothing, salon, spa, nails, and personal care', TRUE, 'variable', FALSE),
  STRUCT('fitness', 'Fitness', 'Home, Health & Clothes', 'expense', 'Gym, fitness, and exercise (adults)', TRUE, 'committed', FALSE),
  STRUCT('healthcare', 'Healthcare', 'Home, Health & Clothes', 'expense', 'Medical, dental, and pharmacy', TRUE, 'variable', TRUE),
  STRUCT('home', 'Home', 'Home, Health & Clothes', 'expense', 'Household goods, furnishings, and everyday home spending', TRUE, 'variable', FALSE),
  STRUCT('pets', 'Pets', 'Home, Health & Clothes', 'expense', 'Pet care and supplies', TRUE, 'variable', TRUE),
  STRUCT('insurance', 'Insurance', 'Mortgage, Bills & School', 'expense', 'Insurance premiums and related costs', TRUE, 'fixed', TRUE),
  STRUCT('housing', 'Housing', 'Mortgage, Bills & School', 'expense', 'Rent, mortgage, and core housing costs', TRUE, 'fixed', TRUE),
  STRUCT('school', 'School', 'Mortgage, Bills & School', 'expense', 'Tuition and after-school programs (aftercare, enrichment)', TRUE, 'committed', TRUE),
  STRUCT('childcare', 'Childcare', 'Mortgage, Bills & School', 'expense', 'Preschool, daycare, and camp', TRUE, 'fixed', TRUE),
  STRUCT('utilities', 'Utilities', 'Mortgage, Bills & School', 'expense', 'Utilities and recurring household bills', TRUE, 'fixed', TRUE),
  STRUCT('babysitters', 'Babysitters', 'Recreation, Travel & Transit', 'expense', 'Occasional evening and weekend sitters', TRUE, 'variable', FALSE),
  STRUCT('car', 'Car', 'Recreation, Travel & Transit', 'expense', 'Vehicle ownership: repair, registration, wash', TRUE, 'variable', TRUE),
  STRUCT('media', 'Media & Entertainment', 'Recreation, Travel & Transit', 'expense', 'Streaming, press, events, and entertainment', TRUE, 'committed', FALSE),
  STRUCT('recreation', 'Recreation', 'Recreation, Travel & Transit', 'expense', 'Recreation and leisure (adults)', TRUE, 'variable', FALSE),
  STRUCT('transportation', 'Transportation', 'Recreation, Travel & Transit', 'expense', 'Getting around: fuel, transit, rideshare, parking', TRUE, 'variable', TRUE),
  STRUCT('travel_vacation', 'Travel & Vacation', 'Recreation, Travel & Transit', 'expense', 'Travel, hotels, and vacations', TRUE, 'variable', FALSE),
  STRUCT('kids_recreation', 'Kids Recreation', 'Recreation, Travel & Transit', 'expense', 'Optional kids activities and outings', TRUE, 'variable', FALSE),
  STRUCT('donations', 'Donations', 'Holiday & Giving', 'expense', 'Charitable donations', TRUE, 'committed', FALSE),
  STRUCT('gifts', 'Gifts', 'Holiday & Giving', 'expense', 'Gifts, birthdays, weddings, and celebrations', TRUE, 'variable', FALSE),
  STRUCT('home_repair', 'Home Repair', 'Home Repair', 'expense', 'Capital, non-recurring repairs and renovation projects', TRUE, 'variable', FALSE),
  STRUCT('home_services', 'Home Services', 'Home Repair', 'expense', 'Recurring household services: cleaning, pest control', TRUE, 'committed', FALSE),
  STRUCT('education', 'Education', 'Other', 'expense', 'Adult education and courses', TRUE, 'committed', FALSE),
  STRUCT('fees', 'Fees', 'Other', 'expense', 'Bank, card, and service fees', TRUE, 'variable', FALSE),
  STRUCT('taxes', 'Taxes', 'Other', 'expense', 'Taxes and estimated tax payments', TRUE, 'fixed', TRUE),
  STRUCT('work_expenses', 'Work Expenses', 'Other', 'expense', 'Business software, subscriptions, and work costs (tax lookback)', TRUE, 'committed', TRUE),
  STRUCT('unclassified', 'Unclassified', 'Other', 'expense', 'Not yet classified', TRUE, 'variable', FALSE),
  -- Retired: these encode how or how much you paid, not what you bought. Spreading is
  -- explicit (gold.amortization_schedule); size and instrument live on the transaction.
  STRUCT('annual_subscriptions', 'Annual Subscriptions', 'Capital & Irregular', 'expense', 'RETIRED - a payment cadence, not a category', FALSE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('major_purchase', 'Major Purchase', 'Capital & Irregular', 'expense', 'RETIRED - size, not a category', FALSE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('cash', 'Cash', 'Other', 'expense', 'RETIRED - payment instrument, not a category', FALSE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('books_media', 'Books & Media', 'Recreation, Travel & Transit', 'expense', 'RETIRED - merged into Media & Entertainment', FALSE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('holidays', 'Holidays', 'Holiday & Giving', 'expense', 'RETIRED - unused; use Gifts', FALSE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('paycheck', 'Paycheck', 'Income', 'income', 'Employment income', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('interest_income', 'Interest Income', 'Income', 'income', 'Interest income', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('other_income', 'Other Income', 'Income', 'income', 'Other income', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('refund', 'Refund', 'Income', 'income', 'Refunds and reimbursements', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('internal_transfer', 'Internal Transfer', 'Transfers', 'transfer', 'Transfers between owned accounts', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('credit_card_payment', 'Credit Card Payment', 'Transfers', 'transfer', 'Credit-card payments', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('loan_repayment', 'Loan Repayment', 'Transfers', 'transfer', 'Loan principal payments', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL)),
  STRUCT('investment_activity', 'Investment Activity', 'Transfers', 'transfer', 'Investment purchases, sales, and sweeps', TRUE, CAST(NULL AS STRING), CAST(NULL AS BOOL))
]) AS seed
ON target.category_id = seed.category_id
WHEN MATCHED THEN UPDATE SET
  category_name = seed.category_name,
  parent_category = seed.parent_category,
  category_kind = seed.category_kind,
  description = seed.description,
  active = seed.is_active,
  cost_behavior = seed.cost_behavior,
  essential = seed.essential
WHEN NOT MATCHED THEN
  INSERT (category_id, category_name, parent_category, category_kind, description, active, created_at, cost_behavior, essential)
  VALUES (seed.category_id, seed.category_name, seed.parent_category, seed.category_kind, seed.description, seed.is_active, CURRENT_TIMESTAMP(), seed.cost_behavior, seed.essential);

CREATE TABLE IF NOT EXISTS `__PROJECT_ID__.__GOLD_DATASET__.category_aliases` (
  source_system STRING NOT NULL,
  source_parent_category STRING,
  source_category STRING NOT NULL,
  category_id STRING NOT NULL,
  notes STRING,
  active BOOL NOT NULL,
  created_at TIMESTAMP NOT NULL
);

MERGE `__PROJECT_ID__.__GOLD_DATASET__.category_aliases` AS target
USING UNNEST([
  STRUCT('tiller' AS source_system, '' AS source_parent_category, 'Restaurants' AS source_category, 'restaurants_bars' AS category_id),
  STRUCT('tiller', '', 'Media', 'media'),
  STRUCT('tiller', '', 'Gym', 'fitness'),
  STRUCT('tiller', '', 'Shopping', 'clothes_grooming'),
  STRUCT('tiller', '', 'Groceries', 'groceries'),
  STRUCT('tiller', '', 'Transfer', 'internal_transfer'),
  STRUCT('tiller', '', 'Transportation', 'transportation'),
  STRUCT('tiller', '', 'Entertainment', 'media'),
  STRUCT('tiller', '', 'Misc', 'unclassified'),
  STRUCT('tiller', '', 'Medical and Dental', 'healthcare'),
  STRUCT('tiller', '', 'Other Income', 'other_income'),
  STRUCT('tiller', '', 'Fitness', 'fitness'),
  STRUCT('tiller', '', 'Home Improvement', 'home_repair'),
  STRUCT('tiller', '', 'Utilities and Bills', 'utilities'),
  STRUCT('tiller', '', 'Travel', 'travel_vacation'),
  STRUCT('tiller', '', 'Paycheck', 'paycheck'),
  STRUCT('tiller', '', 'Bank Fees', 'fees'),
  STRUCT('tiller', '', 'Interest', 'interest_income'),
  STRUCT('tiller', '', 'Gifts', 'gifts'),
  STRUCT('tiller', '', 'Insurance', 'insurance'),
  STRUCT('tiller', '', 'Kids', 'kids_recreation'),
  STRUCT('tiller', '', 'Charity', 'donations'),
  STRUCT('tiller', '', 'Housing', 'housing'),
  STRUCT('tiller', '', 'Uncategorized', 'unclassified'),
  STRUCT('tiller', '', 'Education', 'education'),
  STRUCT('tiller', '', 'Taxes', 'taxes'),
  STRUCT('tiller', '', 'Subscriptions', 'annual_subscriptions'),
  STRUCT('tiller', '', 'Check', 'unclassified'),
  STRUCT('tiller', '', 'Pets', 'pets'),
  STRUCT('tiller', '', 'Loan Repayment', 'loan_repayment'),
  STRUCT('copilot', 'Food & Drink', 'Coffee', 'coffee'),
  STRUCT('copilot', 'Food & Drink', 'Delivery', 'delivery'),
  STRUCT('copilot', 'Food & Drink', 'Groceries', 'groceries'),
  STRUCT('copilot', 'Food & Drink', 'Restaurants & Bars', 'restaurants_bars'),
  STRUCT('copilot', 'Home, Health & Clothes', 'Clothes & Grooming', 'clothes_grooming'),
  STRUCT('copilot', '', 'Clothes', 'clothes_grooming'),
  STRUCT('copilot', 'Home, Health & Clothes', 'Gym', 'fitness'),
  STRUCT('copilot', 'Home, Health & Clothes', 'Healthcare', 'healthcare'),
  STRUCT('copilot', 'Home, Health & Clothes', 'Home', 'home'),
  STRUCT('copilot', 'Mortgage, Bills & School', 'Insurance', 'insurance'),
  STRUCT('copilot', 'Mortgage, Bills & School', 'Rent', 'housing'),
  STRUCT('copilot', 'Mortgage, Bills & School', 'School', 'school'),
  STRUCT('copilot', 'Mortgage, Bills & School', 'Utilities', 'utilities'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Babysitters', 'babysitters'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Books & Media', 'books_media'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Car', 'car'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Media', 'media'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Recreation', 'recreation'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Transportation', 'transportation'),
  STRUCT('copilot', 'Recreation, Travel & Transit', 'Travel & Vacation', 'travel_vacation'),
  STRUCT('copilot', 'Holiday / Presents', 'Donations', 'donations'),
  STRUCT('copilot', 'Holiday / Presents', 'Gifts', 'gifts'),
  STRUCT('copilot', 'Holiday / Presents', 'Kids rec', 'kids_recreation'),
  STRUCT('copilot', 'Holiday / Presents', 'Xmas', 'holidays'),
  STRUCT('copilot', 'Holiday / Presents', 'Christmas 2013', 'holidays'),
  STRUCT('copilot', 'Holiday / Presents', 'Ada’s Bday', 'gifts'),
  STRUCT('copilot', 'Holiday / Presents', 'Bruce’s Bday', 'gifts'),
  STRUCT('copilot', 'Holiday / Presents', 'brucie bike', 'gifts'),
  STRUCT('copilot', '', 'Crystal Xmas ‘25', 'holidays'),
  STRUCT('copilot', '', 'Other presents', 'gifts'),
  STRUCT('copilot', 'Other', 'Cash', 'cash'),
  STRUCT('copilot', 'Other', 'Education', 'education'),
  STRUCT('copilot', 'Other', 'Fee', 'fees'),
  STRUCT('copilot', 'Other', 'Taxes', 'taxes'),
  STRUCT('copilot', 'Other', 'Unclassified', 'unclassified'),
  STRUCT('copilot', 'Other', 'Work Expenses', 'work_expenses'),
  STRUCT('copilot', 'Other', 'New Baby Prep', 'major_purchase'),
  STRUCT('copilot', 'Capital: Other', 'Annual Subs', 'annual_subscriptions'),
  STRUCT('copilot', 'Capital: Other', 'Airpods', 'major_purchase'),
  STRUCT('copilot', 'Capital: Other', 'Car', 'major_purchase'),
  STRUCT('copilot', 'Capital: Other', 'Car Repair (wheels)', 'car'),
  STRUCT('copilot', 'Capital: Other', 'Clothing - annual', 'clothes_grooming'),
  STRUCT('copilot', 'Capital: Other', 'Deposit', 'internal_transfer'),
  STRUCT('copilot', 'Capital: Other', 'New iPhone', 'major_purchase'),
  STRUCT('copilot', 'Capital: Other', 'New rugs', 'major_purchase'),
  STRUCT('copilot', 'Capital: Other', 'Peleton', 'fitness'),
  STRUCT('copilot', 'Capital: Other', 'Rei', 'major_purchase'),
  STRUCT('copilot', 'Capital: Other', 'Taxes', 'taxes'),
  STRUCT('copilot', 'Home Repair', 'AC Fix ‘24', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Basement Remodel', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Bug spraying', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Buy House', 'housing'),
  STRUCT('copilot', 'Home Repair', 'Electrical Update', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Fix Bathroom Toiler', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Fridge repair', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Home repair', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Home Repair: Furnace', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Kitchen Redo', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Leak', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Replace Roof', 'home_repair'),
  STRUCT('copilot', 'Home Repair', 'Washer and Dryer', 'home_repair'),
  STRUCT('copilot', '', 'Fridge', 'major_purchase'),
  STRUCT('copilot', '', 'Garbage Disposal', 'major_purchase'),
  STRUCT('copilot', '', 'Litter robot', 'major_purchase'),
  STRUCT('copilot', '', 'Roof deck', 'home_repair'),
  STRUCT('copilot', 'Vacations', '10 Yr Staycation', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Annas wedding', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Crystal Trip', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Deer Isle', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Florida 24', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'France trip 24', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'France trip ‘25', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Greece', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Hannah PBurg - May', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Maine ‘24', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Maude’s Babyshower', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Michigan 25', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Offsite', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Vacation: Hannah Florida', 'travel_vacation'),
  STRUCT('copilot', 'Vacations', 'Vacation: Matt’s wedding', 'travel_vacation'),
  STRUCT('copilot', '', 'Florida ‘25', 'travel_vacation'),
  STRUCT('copilot', '', 'Fitler Club', 'recreation'),
  STRUCT('copilot', '', 'Issues', 'unclassified'),
  STRUCT('copilot', '', 'Work Capital', 'work_expenses')
]) AS seed
ON target.source_system = seed.source_system
AND REGEXP_REPLACE(LOWER(COALESCE(target.source_parent_category, '')), r'[^a-z0-9]+', '') = REGEXP_REPLACE(LOWER(COALESCE(seed.source_parent_category, '')), r'[^a-z0-9]+', '')
AND REGEXP_REPLACE(LOWER(target.source_category), r'[^a-z0-9]+', '') = REGEXP_REPLACE(LOWER(seed.source_category), r'[^a-z0-9]+', '')
WHEN MATCHED THEN UPDATE SET
  category_id = seed.category_id,
  source_parent_category = seed.source_parent_category,
  source_category = seed.source_category,
  active = TRUE
WHEN NOT MATCHED THEN
  INSERT (source_system, source_parent_category, source_category, category_id, notes, active, created_at)
  VALUES (seed.source_system, NULLIF(seed.source_parent_category, ''), seed.source_category, seed.category_id, 'Seeded from Tiller/Copilot taxonomy review', TRUE, CURRENT_TIMESTAMP());
