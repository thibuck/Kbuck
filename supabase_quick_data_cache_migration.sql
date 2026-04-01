create table if not exists public.global_vin_cache_kbuck (
    vin text primary key,
    odometer text,
    test_date text,
    private_value text,
    real_model text,
    fetched_at timestamptz not null default now(),
    updated_at timestamptz not null default now(),
    constraint global_vin_cache_kbuck_vin_check check (char_length(trim(vin)) > 0)
);

alter table public.global_vin_cache_kbuck
    add column if not exists odometer text,
    add column if not exists test_date text,
    add column if not exists private_value text,
    add column if not exists real_model text,
    add column if not exists fetched_at timestamptz not null default now(),
    add column if not exists updated_at timestamptz not null default now();

create unique index if not exists global_vin_cache_kbuck_vin_idx
    on public.global_vin_cache_kbuck (vin);

alter table public.global_vin_cache_kbuck enable row level security;

create or replace function public.get_quick_data_cache(target_vin text)
returns table (
    vin text,
    odometer text,
    test_date text,
    private_value text,
    real_model text
)
language plpgsql
security definer
set search_path = public
as $$
declare
    clean_vin text;
begin
    if auth.uid() is null then
        return;
    end if;

    clean_vin := upper(regexp_replace(coalesce(target_vin, ''), '[^A-Z0-9]', '', 'g'));

    if clean_vin = '' then
        return;
    end if;

    return query
    select
        c.vin,
        c.odometer,
        c.test_date,
        c.private_value,
        c.real_model
    from public.global_vin_cache_kbuck c
    where c.vin = clean_vin
    limit 1;
end;
$$;

create or replace function public.upsert_quick_data_cache(
    target_vin text,
    target_odometer text,
    target_test_date text,
    target_private_value text,
    target_real_model text
)
returns jsonb
language plpgsql
security definer
set search_path = public
as $$
declare
    clean_vin text;
    clean_odometer text;
    clean_test_date text;
    clean_private_value text;
    clean_real_model text;
begin
    if auth.uid() is null then
        return jsonb_build_object('ok', false, 'reason', 'Not authenticated.');
    end if;

    clean_vin := upper(regexp_replace(coalesce(target_vin, ''), '[^A-Z0-9]', '', 'g'));
    clean_odometer := nullif(trim(coalesce(target_odometer, '')), '');
    clean_test_date := nullif(trim(coalesce(target_test_date, '')), '');
    clean_private_value := nullif(trim(coalesce(target_private_value, '')), '');
    clean_real_model := nullif(trim(coalesce(target_real_model, '')), '');

    if clean_vin = '' then
        return jsonb_build_object('ok', false, 'reason', 'VIN is required.');
    end if;

    if clean_odometer is null or clean_private_value is null then
        return jsonb_build_object('ok', false, 'reason', 'Odometer and private value are required.');
    end if;

    insert into public.global_vin_cache_kbuck (
        vin,
        odometer,
        test_date,
        private_value,
        real_model,
        fetched_at,
        updated_at
    )
    values (
        clean_vin,
        clean_odometer,
        clean_test_date,
        clean_private_value,
        clean_real_model,
        now(),
        now()
    )
    on conflict (vin)
    do update set
        odometer = excluded.odometer,
        test_date = excluded.test_date,
        private_value = excluded.private_value,
        real_model = excluded.real_model,
        updated_at = now();

    return jsonb_build_object('ok', true, 'vin', clean_vin);
end;
$$;
