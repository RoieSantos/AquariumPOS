-- One-off import of the 15 employees from employee.xlsx into StaffUsers, per "from the excel can
-- we add the rest of the employees" / "if there is an existing dont create or dont touch".
--
-- Existence check: skips a row if StaffUsers already has a DisplayName matching either the full
-- name ("First Last") or just the first name (case-insensitive) - the looser first-name check
-- exists because some current accounts likely use a first-name-only DisplayName (e.g. Randy Santos
-- almost certainly already exists as a login - "Cashier: randy" shows up on a real receipt). This
-- runs as a DO block so each row's outcome (created vs skipped, and why) prints to the Messages tab
-- - review that output afterward; nothing here is silent.
--
-- New accounts get username = first name lowercased with spaces removed (no collisions among these
-- 15 first names), password '123456' (hashed), and MustChangePassword = true so each new hire sets
-- their own password on first login.
--
-- NOT imported (left NULL) - Samantha Lumico Samoy's "birthdate" column in the source file decoded
-- to 2026-11-01, a future date that cannot be a real birthdate (see the earlier chat read-out of
-- employee.xlsx) - almost certainly a hire date typed into the wrong column. Ask before guessing
-- what it should actually be.
--
-- Phone numbers: the source file stored these as Excel numbers, which drops a leading "0" from
-- Philippine mobile numbers (e.g. 9851074924 instead of 09851074924) - re-added below for every
-- number except Gladys's, which was already stored as text with its leading zero intact.
--
-- Run this AFTER supabase_staff_users_hr_profile_fields.sql.

do $$
declare
  emp record;
  v_username text;
  v_exists boolean;
begin
  for emp in
    select * from (values
      ('Philip Buseo', 'Nunez',           'Welder',                          'Weekly',      27900::numeric, '2025-03-08'::date, '1983-08-27'::date, '09851074924',    'Pearl Subd. B14 Lot 7',                                              'Cash'),
      ('Randy',        'Santos',          'Manager',                         'SemiMonthly', 15000::numeric, '2025-03-08'::date, null::date,          null,             'Blk 17 Lot 16 Pineview by Filinvest Brgy Sahudulan Tanza Cavite',    'Cash'),
      ('April',        'Logatoc',         'Online Customer Support',         'Weekly',       9300::numeric, '2025-06-01'::date, '1994-04-28'::date, '09053038195',    '02 Pascual Poblete St. Kanluran Naic Cavite',                        'Digital'),
      ('Grace Ann',    'Salinel',         'Online Customer Support',         'Weekly',      12400::numeric, '2025-07-08'::date, '2000-10-19'::date, '09384251727',    'Blk 20 Lot 74 24th St Istana Subd PH Biga Tanza Cavite',             'Digital'),
      ('Emmanuel',     'Taga',            'Tank Maker',                      'Weekly',      32550::numeric, '2026-01-06'::date, '1982-12-03'::date, '09635742913',    'Tanay Rizal',                                                        'Cash'),
      ('Maria Cristina','Casuyon',        'Cashier',                         'Weekly',      13000::numeric, '2026-02-18'::date, '1982-12-26'::date, '09064354477',    'B1 L79 Ph2 Kaia Homes Brgy Hugo Perez Trece Martires Cavite',        'Cash'),
      ('Markzhan',     'Francisco',       'Helper',                          'Weekly',      15000::numeric, null::date,          null::date,          '09128522176',    '#27 Sigasig St Pagsinag Place South Brgy Sabang Naic',               'Cash'),
      ('Drige',        'Ewami',           'Helper',                          'Weekly',      15000::numeric, null::date,          '1987-07-05'::date, '09913729238',    'Istan Subd B14 L19',                                                 'Cash'),
      ('Samantha Lumico','Samoy',         'Online Sales Manager',            'SemiMonthly', 26000::numeric, null::date,          null::date,          '09911722699',    '52 San Antonio II Noveleta Cavite',                                  'Digital'),
      ('Irish Kate',   'Esper',           'Cashier',                         'Weekly',      15000::numeric, null::date,          '2004-12-12'::date, '09948179593',    'Blk 41 Lot 1 Brgy Narra 3 Silang Cavite',                            'Digital'),
      ('Gladys',       'e',               'Cashier',                         'Weekly',      15000::numeric, null::date,          '1986-01-23'::date, '0953 284 2758',  'Blk 36 Lot 13 Zone 3 Bulihan Silang Cavite',                         'Digital'),
      ('Jeffrey C',    'Panigbatan',      'Store Manager',                   'SemiMonthly', 21000::numeric, null::date,          '1981-01-26'::date, '09920587046',    'Blk 86 Lot 57 Ph4 Fatima III Area F Dasma Cavite',                   'Digital'),
      ('Gedeon',       'Ruelo',           'Helper',                          'Weekly',      15000::numeric, null::date,          null::date,          '09605633868',    'Blk 3 Lot 35 Brgy Granados GMA Cavite',                              'Digital'),
      ('Christian Dominic','Orbita',      'Helper',                          'Weekly',      15000::numeric, null::date,          '2004-08-25'::date, '09286241660',    'Blk 11 Lot 22 Brgy Halayhay Tanza Cavite',                           'Digital'),
      ('Nathaniel',    'Viovicente',      'HR Assistant / Digital Marketer', 'SemiMonthly', 17000::numeric, null::date,          null::date,          null,             null,                                                                  'Digital')
    ) as t(first_name, last_name, job_position, pay_cycle, monthly_salary, hire_date, birthdate, phone_number, home_address, payment_method)
  loop
    select exists (
      select 1 from public."StaffUsers" su
      where lower(trim(su."DisplayName")) = lower(trim(emp.first_name || ' ' || emp.last_name))
         or lower(trim(su."DisplayName")) = lower(trim(emp.first_name))
    ) into v_exists;

    if v_exists then
      raise notice 'SKIPPED (already exists): % %', emp.first_name, emp.last_name;
      continue;
    end if;

    v_username := lower(replace(emp.first_name, ' ', ''));

    if exists (select 1 from public."StaffUsers" where "Username" = v_username) then
      raise notice 'SKIPPED (generated username "%" already taken by someone else - add manually): % %', v_username, emp.first_name, emp.last_name;
      continue;
    end if;

    insert into public."StaffUsers" (
      "Username", "PasswordHash", "DisplayName", "MustChangePassword",
      "Position", "PayCycle", "MonthlySalary", "HireDate", "Birthdate", "PhoneNumber", "HomeAddress", "PaymentMethod"
    )
    values (
      v_username, public.hash_password('123456'), emp.first_name || ' ' || emp.last_name, true,
      emp.job_position, emp.pay_cycle, emp.monthly_salary, emp.hire_date, emp.birthdate, emp.phone_number, emp.home_address, emp.payment_method
    );

    raise notice 'CREATED: % % (username: %)', emp.first_name, emp.last_name, v_username;
  end loop;
end $$;
