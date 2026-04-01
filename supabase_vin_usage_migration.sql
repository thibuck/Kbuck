-- Step 1: table to track successful extraction usage per user + VIN
create table if not exists public.vehicle_extraction_usage_kbuck (
    user_id uuid not null references auth.users(id) on delete cascade,
    vin text not null,
    successful_extractions integer not null default 0,
    last_success_at timestamptz,
    created_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint vehicle_extraction_usage_kbuck_pkey primary key (user_id, vin),
    constraint vehicle_extraction_usage_kbuck_vin_check check (char_length(trim(vin)) > 0)
);

create index if not exists vehicle_extraction_usage_kbuck_user_idx
    on public.vehicle_extraction_usage_kbuck(user_id);

create index if not exists vehicle_extraction_usage_kbuck_vin_idx
    on public.vehicle_extraction_usage_kbuck(vin);

alter table public.vehicle_extraction_usage_kbuck enable row level security;

drop policy if exists "Users can view their own vehicle extraction usage" on public.vehicle_extraction_usage_kbuck;
create policy "Users can view their own vehicle extraction usage"
on public.vehicle_extraction_usage_kbuck
for select
to authenticated
using (auth.uid() = user_id);

-- No direct insert/update/delete from client; only RPCs should mutate this table.

-- Step 2: validate both daily quota and per-VIN quota
create or replace function public.can_extract_data(target_vin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    current_user_id uuid;
    clean_vin text;
    user_tier text;
    user_role text;
    daily_count int;
    max_limit int;
    last_reset timestamptz;
    vin_success_count int;
    per_vin_limit int := 3;
begin
    current_user_id := auth.uid();
    clean_vin := upper(regexp_replace(coalesce(target_vin, ''), '[^A-Z0-9]', '', 'g'));

    if current_user_id is null then
        return jsonb_build_object('allowed', false, 'reason', 'Not authenticated.');
    end if;

    if clean_vin = '' then
        return jsonb_build_object('allowed', false, 'reason', 'VIN is required.');
    end if;

    select p.plan_tier, p.role, coalesce(p.scrape_count_today, 0), p.last_scrape_reset
    into user_tier, user_role, daily_count, last_reset
    from public.profiles_kbuck p
    where p.id = current_user_id;

    if not found then
        return jsonb_build_object('allowed', false, 'reason', 'Profile not found.');
    end if;

    if user_role = 'super_admin' then
        return jsonb_build_object('allowed', true, 'reason', null);
    end if;

    if last_reset is null
       or date_trunc('day', last_reset at time zone 'America/Chicago')
          < date_trunc('day', now() at time zone 'America/Chicago') then
        daily_count := 0;
    end if;

    select st.daily_fetch_limit
    into max_limit
    from public.subscription_tiers_kbuck st
    where lower(st.tier_name) = lower(coalesce(user_tier, 'free'))
    limit 1;

    if max_limit is null then
        max_limit := 3;
    end if;

    if daily_count >= max_limit then
        return jsonb_build_object(
            'allowed', false,
            'reason', 'Daily limit reached for your current plan. Upgrade to unlock more.'
        );
    end if;

    select coalesce(veu.successful_extractions, 0)
    into vin_success_count
    from public.vehicle_extraction_usage_kbuck veu
    where veu.user_id = current_user_id
      and veu.vin = clean_vin;

    vin_success_count := coalesce(vin_success_count, 0);

    if vin_success_count >= per_vin_limit then
        return jsonb_build_object(
            'allowed', false,
            'reason', format('You have reached the maximum of %s successful extractions for this vehicle.', per_vin_limit)
        );
    end if;

    return jsonb_build_object('allowed', true, 'reason', null);
end;
$$;

-- Step 3: increment both daily quota and per-VIN usage atomically
create or replace function public.increment_fetch_count(target_vin text)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    current_user_id uuid;
    clean_vin text;
    user_tier text;
    user_role text;
    daily_count int;
    max_limit int;
    last_reset timestamptz;
    new_daily_count int;
    vin_success_count int;
    per_vin_limit int := 3;
begin
    current_user_id := auth.uid();
    clean_vin := upper(regexp_replace(coalesce(target_vin, ''), '[^A-Z0-9]', '', 'g'));

    if current_user_id is null then
        return jsonb_build_object('ok', false, 'incremented', false, 'reason', 'Not authenticated.');
    end if;

    if clean_vin = '' then
        return jsonb_build_object('ok', false, 'incremented', false, 'reason', 'VIN is required.');
    end if;

    select p.plan_tier, p.role, coalesce(p.scrape_count_today, 0), p.last_scrape_reset
    into user_tier, user_role, daily_count, last_reset
    from public.profiles_kbuck p
    where p.id = current_user_id
    for update;

    if not found then
        return jsonb_build_object('ok', false, 'incremented', false, 'reason', 'Profile not found.');
    end if;

    if user_role = 'super_admin' then
        return jsonb_build_object('ok', true, 'incremented', false, 'reason', 'super_admin exempt');
    end if;

    if last_reset is null
       or date_trunc('day', last_reset at time zone 'America/Chicago')
          < date_trunc('day', now() at time zone 'America/Chicago') then
        daily_count := 0;
    end if;

    select st.daily_fetch_limit
    into max_limit
    from public.subscription_tiers_kbuck st
    where lower(st.tier_name) = lower(coalesce(user_tier, 'free'))
    limit 1;

    if max_limit is null then
        max_limit := 3;
    end if;

    if daily_count >= max_limit then
        return jsonb_build_object('ok', false, 'incremented', false, 'reason', 'Daily limit reached.');
    end if;

    select coalesce(veu.successful_extractions, 0)
    into vin_success_count
    from public.vehicle_extraction_usage_kbuck veu
    where veu.user_id = current_user_id
      and veu.vin = clean_vin
    for update;

    vin_success_count := coalesce(vin_success_count, 0);

    if vin_success_count >= per_vin_limit then
        return jsonb_build_object(
            'ok', false,
            'incremented', false,
            'reason', format('You have reached the maximum of %s successful extractions for this vehicle.', per_vin_limit)
        );
    end if;

    if last_reset is null
       or date_trunc('day', last_reset at time zone 'America/Chicago')
          < date_trunc('day', now() at time zone 'America/Chicago') then
        update public.profiles_kbuck
        set scrape_count_today = 1,
            last_scrape_reset = now(),
            total_fetches = coalesce(total_fetches, 0) + 1
        where id = current_user_id;

        new_daily_count := 1;
    else
        update public.profiles_kbuck
        set scrape_count_today = coalesce(scrape_count_today, 0) + 1,
            total_fetches = coalesce(total_fetches, 0) + 1
        where id = current_user_id;

        new_daily_count := daily_count + 1;
    end if;

    insert into public.vehicle_extraction_usage_kbuck (
        user_id,
        vin,
        successful_extractions,
        last_success_at,
        updated_at
    )
    values (
        current_user_id,
        clean_vin,
        1,
        now(),
        now()
    )
    on conflict (user_id, vin)
    do update set
        successful_extractions = public.vehicle_extraction_usage_kbuck.successful_extractions + 1,
        last_success_at = now(),
        updated_at = now();

    return jsonb_build_object(
        'ok', true,
        'incremented', true,
        'daily_count', new_daily_count,
        'daily_limit', max_limit,
        'vin', clean_vin,
        'vin_success_count', vin_success_count + 1,
        'vin_limit', per_vin_limit,
        'reason', null
    );
end;
$$;
