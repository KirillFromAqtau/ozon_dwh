# Ozon DWH — аналитическое хранилище для магазина на Ozon

[![CI](https://github.com/KirillFromAqtau/ozon_dwh/actions/workflows/ci.yml/badge.svg)](https://github.com/KirillFromAqtau/ozon_dwh/actions/workflows/ci.yml)
[![Ozon daily load](https://github.com/KirillFromAqtau/ozon_dwh/actions/workflows/ozon-daily.yml/badge.svg)](https://github.com/KirillFromAqtau/ozon_dwh/actions/workflows/ozon-daily.yml)

> **EN:** Production data warehouse for a real Ozon marketplace shop (3D-printed goods).
> Daily ELT from Ozon Seller API into PostgreSQL (`raw → core → mart`), calculating true unit economics
> per product after marketplace fees, logistics, penalties and production cost.
> Runs in production every day on GitHub Actions + Neon serverless Postgres at **$0/month**;
> Apache Airflow 3 is used for local development. Tested on real PostgreSQL in CI.

Хранилище данных для реального магазина 3D-печатных товаров, который продаёт через Ozon по схеме FBS (кросс-бордер, Казахстан → Россия).
Проект ежедневно забирает заказы и финансовые начисления из Ozon Seller API, приводит их к аналитической модели и считает **чистую юнит-экономику каждого товара**: сколько реально приходит на счёт после комиссии, логистики, штрафов и возвратов, за вычетом себестоимости печати.

## Стек

| Слой | Технологии |
|---|---|
| Источник | Ozon Seller API (`/v4/posting/fbs/list`, `/v1/finance/accrual/by-day`) |
| Загрузка | Python 3, `requests`, `psycopg2` |
| Хранилище | PostgreSQL 16 (слои `raw` → `core` → `mart`): **Neon** в проде, Docker локально |
| Оркестрация | **GitHub Actions (cron)** в проде, **Apache Airflow 3.2** локально |
| Инфраструктура | Docker Compose, GitHub Secrets |
| Качество | pytest (тесты на реальном PostgreSQL), ruff, GitHub Actions |

## Архитектура

```
Ozon Seller API
      │  Python-загрузчики (пагинация курсором, ретраи 429/5xx)
      ▼
raw.*   — ответы API как есть (JSONB), upsert по естественному ключу
      │  SQL-трансформации (идемпотентные)
      ▼
core.*  — нормализованная модель: отправления, товары, начисления,
          закупки материалов, принтеры, ставки себестоимости
      │
      ▼
mart.*  — витрины: юнит-экономика, себестоимость, продажи по дням,
          статистика производства
```

Цепочка шагов одинаковая в проде и локально (ежедневно 07:00, Asia/Aqtau):

```
migrate ─► load_fbs_postings ─► load_accruals ─► refresh_products ─► dq_checks
```

## Окружения

| | dev | test (CI) | prod |
|---|---|---|---|
| Где | MacBook, Docker Compose | GitHub Actions, каждый push | GitHub Actions, cron 07:00 |
| База | PostgreSQL 16 в Docker | PostgreSQL 16 (service container) | Neon, PostgreSQL 16 (Frankfurt) |
| Оркестрация | Airflow 3.2 (`dags/ozon_daily.py`) | — | `.github/workflows/ozon-daily.yml` |
| Секреты | `.env` (в `.gitignore`) | тестовые значения | GitHub Secrets |
| Стоимость | — | $0 | **$0** |

Версия PostgreSQL одна и та же во всех окружениях: всё, что прошло тесты, ведёт себя так же в проде.

## Ключевые решения

- **ELT через слой raw.** Сырые ответы API хранятся целиком в JSONB, поэтому логику разбора можно поменять и пересобрать `core` без повторных запросов к API.
- **Идемпотентность.** Каждый шаг можно перезапустить без дублей: `INSERT … ON CONFLICT DO UPDATE`, перезаливка дня начислений целиком, одна транзакция на загрузку.
- **Скользящее окно перезагрузки.** Отправления перезабираются за 30 дней (статус меняется `delivering → delivered` в течение ~2 недель), начисления — за 14 дней (Ozon досписывает задним числом).
- **Начисления раскладываются на «атомы».** Одно начисление Ozon (продажа, комиссия, каждая услуга логистики, штраф, сбор по товару) — отдельная строка с типом и группой. Поверх идёт **контроль сверки**: если сумма атомов не равна `total_amount`, разница пишется в строку `Unparsed`, и проверка качества роняет DAG. Так новые неизвестные блоки ответа API не теряются молча.
- **Миграция на новые API Ozon (осень 2026).** `/v3/posting/fbs/list` → `/v4` (курсорная пагинация, лимит 100, цены объектом `{amount, currency}`); `/v3/finance/transaction/list` → `/v1/finance/accrual/by-day`. Структура ответов изучена на реальных данных до написания парсера.
- **Себестоимость из реальных данных производства:** средневзвешенная цена пластика из закупок + электричество + амортизация принтеров + упаковка; нормативы граммов и минут печати — из слайсера.
- **Выбор продакшена по деньгам.** VPS, на котором поместится Airflow (от 4 ГБ RAM), стоил бы ~7 600 ₸ в месяц — заметная доля прибыли небольшого магазина. Сами загрузчики лёгкие, поэтому прод — это та же цепочка шагов в GitHub Actions по расписанию плюс бесплатный Neon: **$0 в месяц**. DAG для Airflow остаётся в репозитории; переезд на свой сервер с Airflow не потребует изменений в коде загрузчиков.
- **Секреты:** локально в `.env`, в проде — GitHub Secrets (в логах маскируются `***`). Логи публичного репозитория содержат только служебные сообщения и количества строк — без сумм и названий товаров.
- **Перенос dev → prod** выполнен через `pg_dump | psql` без промежуточного файла; дальше схема в проде обновляется сама задачей `migrate`.

## Проверки качества данных (`src/dq_checks.py`)

| Проверка | Уровень |
|---|---|
| Неразобранные начисления (`Unparsed`) | FAIL |
| Отправления без товаров | FAIL |
| Нет новых отправлений за 3 дня | WARN |
| Проданные товары без себестоимости | WARN |
| Типы начислений вне известных групп | WARN |

## Структура проекта

```
dags/ozon_daily.py                 Airflow DAG
src/db.py                          общее подключение к БД
src/migrate.py                     применение схемы (идемпотентно)
src/load_fbs_postings.py           API → raw → core (отправления)
src/load_accruals.py               API → raw → core (начисления)
src/product_costs.py               выгрузка/загрузка себестоимости через CSV
src/run_sql.py                     запуск SQL-файлов
src/dq_checks.py                   проверки качества
sql/init/                          создание базы Airflow при первом старте
sql/schema/01_schema.sql           таблицы raw/core/mart
sql/schema/02_marts.sql            витрины
sql/migrations/                    изменения схемы
sql/transform/                     raw → core
sql/seed/my_setup.example.sql      образец справочников производства
                                   (реальный my_setup.sql — в .gitignore)
tests/                             pytest + обезличенные фикстуры ответов API
.github/workflows/ci.yml           CI: ruff, тесты, импорт DAG
docker-compose.yml                 PostgreSQL + Airflow
```

## Запуск

```bash
cp .env.example .env                                     # ключи Ozon, логин/пароль БД
cp sql/seed/my_setup.example.sql sql/seed/my_setup.sql   # свои цены закупок
docker compose up -d                                     # PostgreSQL + Airflow: http://localhost:8080

python -m venv .venv && source .venv/bin/activate && pip install -r requirements-dev.txt
python src/migrate.py                                    # схема (DAG тоже делает это первым шагом)
python src/load_fbs_postings.py --days 180               # первичная загрузка истории
python src/load_accruals.py --days 180
```

## Тесты и CI

Тесты гоняются на **настоящем PostgreSQL**, а не на моках: схема создаётся с нуля
тем же `migrate.py`, что и в проде, в raw кладутся обезличенные образцы ответов API,
затем запускаются те же SQL-трансформации, что и в DAG.

Что проверяется:
- разбор отправлений: цена объектом (v4) и строкой (v3), пустые даты, несколько товаров;
- разбор начислений: **сумма «атомов» равна `total_amount` Ozon**, группы, неизвестный блок попадает в `Unparsed`;
- юнит-экономика на ручном расчёте;
- идемпотентность: повторный запуск миграций и трансформаций не создаёт дублей;
- DQ-проверки и импорт DAG в Airflow 3.

```bash
docker exec ozon_dwh_pg createdb -U <PG_USER> ozon_test
PG_DB=ozon_test pytest -v       # база обязана оканчиваться на _test — защита от запуска на проде
```

GitHub Actions при каждом push: `ruff` → чистая установка схемы → `pytest` → проверка импорта DAG.

## Продакшен (GitHub Actions + Neon)

```bash
# секреты для workflow ozon-daily.yml
gh secret set OZON_CLIENT_ID
gh secret set OZON_API_KEY
gh secret set PG_HOST          # ep-....neon.tech (без -pooler)
gh secret set PG_USER
gh secret set PG_PASSWORD
gh secret set PG_DB

gh workflow run ozon-daily.yml # ручной запуск
gh run watch                   # следить за прогоном
gh run list --workflow=ozon-daily.yml --limit 5
```

Если шаг упал — GitHub присылает письмо; `gh run view --log-failed` показывает ошибку.

## Что дал проект бизнесу

- Найдено, что основная статья потерь — **плата за просроченную отгрузку** FBS: по сумме она превышала комиссию маркетплейса. По данным изменены настройки времени приёма заказов и запущено производство в запас для топ-позиций.
- Выявлены товары, убыточные из-за фиксированной логистики на дешёвых позициях; рассчитаны минимальные цены.
- Эффект изменений отслеживается в тех же витринах (штрафы по неделям).

## Планы

- Дашборды в Superset
- Витрина рекомендуемых цен
- Журнал печати: загрузка принтеров и процент брака
