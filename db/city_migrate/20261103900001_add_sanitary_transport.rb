# Módulo 30 (ADR 0048): transporte sanitário e Tratamento Fora de Domicílio.
# Frota (veículos, motoristas com CNH cifrada, destinos com km), parâmetros
# (uma linha, id 1, inserida aqui), séries recorrentes, viagens com paradas e
# passageiros sem dado clínico, diário de bordo e correções de presença
# (imutáveis), pendências da série e avisos ao cidadão. Veículo e motorista
# nunca em duas viagens que se cruzam: exclusion GiST sobre
# tsrange(departure_at, return_at) — meio-aberto, a viagem que volta às 12:00
# e a que sai às 12:00 não se cruzam; a cancelada não ocupa. Sem CHECK de data
# (decisão do coordenador): o dump é um só para cidades de fuso diferente; a
# data vem da saída no fuso da cidade, no Ruby (TransportTrip). O TFD: processo
# (laudo JSON cifrado), andamento, trechos, ajuda de custo, pagamento e
# prestação de contas (só acréscimo). O prestador ganha o município, o pedido
# de regulação o prestador, a unidade o tipo health_management, o BPA a fonte
# tfd e o arquivo de exame o propósito tfd_accountability. Nome, documento,
# CNH, prestador, endereço, motivos e laudo cifrados com a chave da cidade.
# Triggers em db/city_triggers.sql (o dump não representa trigger nem linha).
# Irreversível.
class AddSanitaryTransport < ActiveRecord::Migration[8.1]
  ROLES = %w[analyst billing_clerk campaign_manager care_regulator citizen_verifier driver exam_provider exam_regulator
             health_professional lab_releaser lab_staff municipal_admin pharmacist pharmacy_assistant protocol_author
             protocol_publisher protocol_reviewer stock_keeper surveillance tfd_committee transport_dispatcher viewer].freeze
  HEALTH_UNIT_KINDS = %w[ubs upa hospital other ceo health_management].freeze
  SOURCES = %w[attendance consultation lab_report manual tfd].freeze
  INSTRUMENTS = %w[bpa_i bpa_c not_bpa].freeze
  CHARACTERS = %w[elective urgent].freeze
  EXAM_FILE_PURPOSES = %w[eqa_annual_report tfd_accountability].freeze
  # Espelho de Transport::Catalog e Tfd::Catalog no dia desta migração (a
  # migração não lê código da aplicação: a lista do banco fica fixa no que foi
  # migrado).
  VEHICLE_KINDS = %w[van minibus bus car ambulance_a].freeze
  LICENSE_CATEGORIES = %w[B C D E].freeze
  TRIP_STATUSES = %w[planned confirmed in_progress done cancelled].freeze
  STOP_KINDS = %w[boarding destination].freeze
  ORIGINS = %w[regulation appointment tfd series exception].freeze
  EXCEPTION_REASONS = %w[follow_up_return legacy_patient scheduling_pending other].freeze
  ATTENDANCE = %w[pending boarded no_show].freeze
  ATTENDANCE_FIELDS = %w[attendance companion_attendance].freeze
  NOTICE_KINDS = %w[added departure_changed boarding_changed cancelled removed reminder].freeze
  PENDING_REASONS = %w[no_seat no_wheelchair_spot].freeze
  # §14 T18: sem `lodging`.
  EXPENSE_KINDS = %w[toll parking meal other].freeze
  SEATS = (1..60)
  WHEELCHAIR_SPOTS = (0..10)
  MAX_TRIP_HOURS = 72
  ODOMETER = (0..9_999_999)
  TFD_STATUSES = %w[draft submitted returned authorized denied scheduled travelling completed cancelled].freeze
  TFD_EVENT_KINDS = (TFD_STATUSES - %w[draft] + %w[created appointment_set inpatient_recorded]).freeze
  MODES = %w[fleet bus_ticket air river].freeze
  DIRECTIONS = %w[outbound return].freeze
  ALLOWANCE_KINDS = %w[meal_overnight meal_day ground_km air_miles river_miles].freeze
  PERSONS = %w[patient companion].freeze
  PAYMENT_METHODS = %w[cash transfer pix check].freeze
  # Trecho de frota anulado (a pessoa saiu da viagem, a viagem caiu ou faltou).
  VOID_REASONS = %w[passenger_removed trip_cancelled no_show].freeze
  MAX_AMOUNT_CENTS = 10_000_000
  COMPETENCE = "'^[0-9]{4}(0[1-9]|1[0-2])$'::text".freeze

  def up
    replace_check :memberships, "ck_memberships_role", "role::text = ANY (ARRAY[#{quoted(ROLES)}]::text[])"
    replace_check :health_units, "ck_health_units_kind", "kind::text = ANY (ARRAY[#{quoted(HEALTH_UNIT_KINDS)}]::text[])"
    replace_check :exam_files, "ck_exam_files_purpose",
                  "purpose IS NULL OR purpose::text = ANY (ARRAY[#{quoted(EXAM_FILE_PURPOSES)}]::text[])"

    # Município do prestador (nulo = a própria cidade) e o prestador do
    # agendamento externo do 26a (Desvio 6: só o NOME chega ao passageiro).
    add_column :care_providers, :ibge_code, :string, limit: 7
    add_check_constraint :care_providers, "ibge_code IS NULL OR ibge_code::text ~ '^[0-9]{7}$'::text", name: "ck_care_providers_ibge_code"
    add_reference :regulation_requests, :care_provider, type: :uuid, foreign_key: true, index: false
    add_index :regulation_requests, :care_provider_id, where: "care_provider_id IS NOT NULL", name: "idx_regulation_requests_care_provider"

    create_fleet
    create_series_and_trips
    create_passengers
    create_trip_records
    create_tfd
    change_performed_procedures

    execute File.read(Rails.root.join("db/city_triggers.sql"))
  end

  def down
    raise ActiveRecord::IrreversibleMigration
  end

  private

  def create_fleet
    create_table :transport_settings, id: :smallint do |t|
      t.integer :tfd_min_distance_km, null: false, default: 50
      t.integer :companion_max_age_child, null: false, default: 15
      t.integer :companion_min_age_elderly, null: false, default: 60
      t.references :tfd_billing_health_unit, type: :uuid, foreign_key: { to_table: :health_units }, index: false
      t.jsonb :allowance_complements, null: false, default: {}
      t.references :updated_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :updated_at, null: false
    end
    add_check_constraint :transport_settings, "id = 1", name: "ck_transport_settings_singleton"
    add_check_constraint :transport_settings,
                         "tfd_min_distance_km >= 1 AND tfd_min_distance_km <= 1000 AND " \
                         "companion_max_age_child >= 0 AND companion_max_age_child <= 17 AND " \
                         "companion_min_age_elderly >= 50 AND companion_min_age_elderly <= 100",
                         name: "ck_transport_settings_ranges"
    add_check_constraint :transport_settings, "jsonb_typeof(allowance_complements) = 'object'::text",
                         name: "ck_transport_settings_complements"
    execute "INSERT INTO transport_settings (id, updated_at) VALUES (1, now()) ON CONFLICT (id) DO NOTHING"

    create_table :transport_vehicles, id: :uuid do |t|
      t.string :plate, limit: 7, null: false
      t.string :renavam, limit: 11, null: false
      t.string :model, limit: 80, null: false
      t.string :kind, null: false
      t.string :renem_code, limit: 20
      t.integer :seats, null: false
      t.integer :wheelchair_spots, null: false, default: 0
      t.string :cnes, limit: 7
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :transport_vehicles, :plate, unique: true, name: "idx_transport_vehicles_plate"
    add_index :transport_vehicles, :renavam, unique: true, name: "idx_transport_vehicles_renavam"
    add_check_constraint :transport_vehicles,
                         "kind::text = ANY (ARRAY[#{quoted(VEHICLE_KINDS)}]::text[]) AND " \
                         "plate::text ~ '^[A-Z]{3}[0-9][A-Z0-9][0-9]{2}$'::text AND renavam::text ~ '^[0-9]{11}$'::text AND " \
                         "(cnes IS NULL OR cnes::text ~ '^[0-9]{7}$'::text)",
                         name: "ck_transport_vehicles_domains"
    add_check_constraint :transport_vehicles,
                         "seats >= #{SEATS.min} AND seats <= #{SEATS.max} AND " \
                         "wheelchair_spots >= #{WHEELCHAIR_SPOTS.min} AND wheelchair_spots <= #{WHEELCHAIR_SPOTS.max}",
                         name: "ck_transport_vehicles_ranges"

    create_table :transport_drivers, id: :uuid do |t|
      t.references :user, type: :uuid, null: false, foreign_key: true, index: false
      # Número da CNH: cifrado com a chave da cidade.
      t.text :license_number, null: false
      t.string :license_category, null: false
      t.date :license_expires_on, null: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :transport_drivers, :user_id, unique: true, name: "idx_transport_drivers_user"
    add_check_constraint :transport_drivers, "license_category::text = ANY (ARRAY[#{quoted(LICENSE_CATEGORIES)}]::text[])",
                         name: "ck_transport_drivers_category"

    create_table :transport_destinations, id: :uuid do |t|
      t.string :ibge_code, limit: 7, null: false
      t.string :name, limit: 120, null: false
      t.integer :distance_km, null: false
      t.boolean :metropolitan, null: false, default: false
      t.boolean :active, null: false, default: true
      t.references :updated_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :transport_destinations, :ibge_code, unique: true, name: "idx_transport_destinations_ibge"
    add_check_constraint :transport_destinations, "ibge_code::text ~ '^[0-9]{7}$'::text AND distance_km >= 0",
                         name: "ck_transport_destinations_domains"
  end

  def create_series_and_trips
    create_table :transport_series, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :transport_destination, type: :uuid, null: false, foreign_key: true, index: false
      # Prestador e endereço: cifrados.
      t.text :provider_name
      t.text :address
      t.integer :weekdays, limit: 2, array: true, null: false
      t.time :appointment_time, null: false
      t.time :departure_time, null: false
      t.time :return_time, null: false
      t.string :boarding_label, limit: 120, null: false
      t.date :starts_on, null: false
      t.date :ends_on
      t.boolean :wheelchair, null: false, default: false
      # Acompanhante (nome, documento, motivo) e motivo da suspensão: cifrados.
      t.text :companion_name
      t.text :companion_document
      t.text :companion_reason
      t.date :suspended_from
      t.text :suspend_reason
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :transport_series, :patient_id, name: "idx_transport_series_patient"
    add_index :transport_series, :transport_destination_id, name: "idx_transport_series_destination"
    add_check_constraint :transport_series, "cardinality(weekdays) >= 1 AND weekdays <@ ARRAY[1, 2, 3, 4, 5, 6, 7]::smallint[]",
                         name: "ck_transport_series_weekdays"
    add_check_constraint :transport_series, "return_time > departure_time", name: "ck_transport_series_times"
    add_check_constraint :transport_series, "ends_on IS NULL OR ends_on >= starts_on", name: "ck_transport_series_dates"
    add_check_constraint :transport_series, "(suspended_from IS NULL) = (suspend_reason IS NULL)", name: "ck_transport_series_suspend"

    create_table :transport_trips, id: :uuid do |t|
      t.date :date, null: false
      t.datetime :departure_at, null: false
      t.datetime :return_at, null: false
      t.references :transport_vehicle, type: :uuid, foreign_key: true, index: false
      t.references :transport_driver, type: :uuid, foreign_key: true, index: false
      t.string :status, null: false, default: "planned"
      t.references :transport_series, type: :uuid, foreign_key: true, index: false
      # Motivo do cancelamento: cifrado.
      t.text :cancel_reason
      t.datetime :cancelled_at
      t.references :cancelled_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :confirmed_at
      t.datetime :started_at
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :transport_trips, %i[date status], name: "idx_transport_trips_date_status"
    add_index :transport_trips, :transport_series_id, where: "transport_series_id IS NOT NULL", name: "idx_transport_trips_series"
    add_index :transport_trips, :transport_driver_id, where: "transport_driver_id IS NOT NULL", name: "idx_transport_trips_driver"
    add_check_constraint :transport_trips, "status::text = ANY (ARRAY[#{quoted(TRIP_STATUSES)}]::text[])", name: "ck_transport_trips_status"
    add_check_constraint :transport_trips,
                         "return_at > departure_at AND return_at <= (departure_at + '#{MAX_TRIP_HOURS} hours'::interval)",
                         name: "ck_transport_trips_range"
    add_check_constraint :transport_trips,
                         "(status::text <> ALL (ARRAY['confirmed'::text, 'in_progress'::text, 'done'::text])) OR " \
                         "(transport_vehicle_id IS NOT NULL AND transport_driver_id IS NOT NULL)",
                         name: "ck_transport_trips_staffed"
    add_check_constraint :transport_trips, "(status::text = 'cancelled'::text) = (cancelled_at IS NOT NULL)", name: "ck_transport_trips_cancel"
    # Desvio 2: meio-aberto ([) — encostar não é cruzar; cancelada não ocupa.
    add_exclusion_constraint :transport_trips, "transport_vehicle_id WITH =, tsrange(departure_at, return_at) WITH &&",
                             using: :gist, where: "status::text <> 'cancelled'::text AND transport_vehicle_id IS NOT NULL",
                             name: "excl_transport_trips_vehicle"
    add_exclusion_constraint :transport_trips, "transport_driver_id WITH =, tsrange(departure_at, return_at) WITH &&",
                             using: :gist, where: "status::text <> 'cancelled'::text AND transport_driver_id IS NOT NULL",
                             name: "excl_transport_trips_driver"

    create_table :transport_trip_stops, id: :uuid do |t|
      t.references :transport_trip, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :position, limit: 2, null: false
      t.string :kind, null: false
      t.references :transport_destination, type: :uuid, foreign_key: true, index: false
      t.string :label, limit: 120, null: false
    end
    add_index :transport_trip_stops, %i[transport_trip_id position], unique: true, name: "idx_transport_trip_stops_position"
    add_check_constraint :transport_trip_stops,
                         "kind::text = ANY (ARRAY[#{quoted(STOP_KINDS)}]::text[]) AND position >= 1 AND " \
                         "(kind::text = 'destination'::text) = (transport_destination_id IS NOT NULL)",
                         name: "ck_transport_trip_stops_kind"
  end

  def create_passengers
    create_table :transport_trip_passengers, id: :uuid do |t|
      t.references :transport_trip, type: :uuid, null: false, foreign_key: true, index: false
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :transport_trip_stop, type: :uuid, null: false, foreign_key: true, index: false
      t.references :transport_destination, type: :uuid, null: false, foreign_key: true, index: false
      # Prestador e endereço: cifrados.
      t.text :provider_name
      t.text :address
      t.datetime :appointment_at
      t.boolean :takes_seat, null: false, default: true
      t.boolean :wheelchair, null: false, default: false
      # Acompanhante (nome, documento, motivo): cifrados.
      t.text :companion_name
      t.text :companion_document
      t.text :companion_reason
      t.string :origin, null: false
      t.references :regulation_request, type: :uuid, foreign_key: true, index: false
      t.references :appointment, type: :uuid, foreign_key: true, index: false
      t.references :tfd_case, type: :uuid, index: false
      t.references :transport_series, type: :uuid, foreign_key: true, index: false
      t.string :exception_reason
      # Nota da exceção e motivo da retirada: cifrados.
      t.text :exception_note
      t.string :attendance, null: false, default: "pending"
      t.string :companion_attendance
      t.references :added_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.datetime :removed_at
      t.references :removed_by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      t.text :remove_reason
      t.datetime :anonymized_at
      t.timestamps
    end
    add_index :transport_trip_passengers, %i[transport_trip_id patient_id], unique: true, where: "removed_at IS NULL",
                                                                            name: "idx_transport_trip_passengers_active"
    add_index :transport_trip_passengers, :transport_trip_id, name: "idx_transport_trip_passengers_trip"
    add_index :transport_trip_passengers, :patient_id, name: "idx_transport_trip_passengers_patient"
    add_index :transport_trip_passengers, :transport_trip_stop_id, name: "idx_transport_trip_passengers_stop"
    add_index :transport_trip_passengers, :tfd_case_id, where: "tfd_case_id IS NOT NULL", name: "idx_transport_trip_passengers_tfd_case"
    # Desvio 4: uma referência e só a da origem; a exceção sem referência e com motivo.
    add_check_constraint :transport_trip_passengers,
                         "num_nonnulls(regulation_request_id, appointment_id, tfd_case_id, transport_series_id) = " \
                         "((origin::text <> 'exception'::text))::integer AND " \
                         "(regulation_request_id IS NOT NULL) = (origin::text = 'regulation'::text) AND " \
                         "(appointment_id IS NOT NULL) = (origin::text = 'appointment'::text) AND " \
                         "(tfd_case_id IS NOT NULL) = (origin::text = 'tfd'::text) AND " \
                         "(transport_series_id IS NOT NULL) = (origin::text = 'series'::text) AND " \
                         "(origin::text = 'exception'::text) = (exception_reason IS NOT NULL)",
                         name: "ck_transport_trip_passengers_origin"
    add_check_constraint :transport_trip_passengers,
                         "anonymized_at IS NOT NULL OR (companion_name IS NULL) = (companion_attendance IS NULL)",
                         name: "ck_transport_trip_passengers_companion"
    add_check_constraint :transport_trip_passengers,
                         "origin::text = ANY (ARRAY[#{quoted(ORIGINS)}]::text[]) AND " \
                         "(exception_reason IS NULL OR exception_reason::text = ANY (ARRAY[#{quoted(EXCEPTION_REASONS)}]::text[])) AND " \
                         "attendance::text = ANY (ARRAY[#{quoted(ATTENDANCE)}]::text[]) AND " \
                         "(companion_attendance IS NULL OR companion_attendance::text = ANY (ARRAY[#{quoted(ATTENDANCE)}]::text[]))",
                         name: "ck_transport_trip_passengers_domains"
  end

  def create_trip_records
    create_table :transport_trip_logs, id: :uuid do |t|
      t.references :transport_trip, type: :uuid, null: false, foreign_key: true, index: false
      t.integer :odometer_start, null: false
      t.integer :odometer_end, null: false
      t.jsonb :fuel, null: false, default: []
      t.jsonb :expenses, null: false, default: []
      t.datetime :closed_at, null: false
      t.references :closed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
    end
    add_index :transport_trip_logs, :transport_trip_id, unique: true, name: "idx_transport_trip_logs_trip"
    add_check_constraint :transport_trip_logs,
                         "odometer_start >= #{ODOMETER.min} AND odometer_end <= #{ODOMETER.max} AND odometer_end >= odometer_start",
                         name: "ck_transport_trip_logs_odometer"
    add_check_constraint :transport_trip_logs, "jsonb_typeof(fuel) = 'array'::text AND jsonb_typeof(expenses) = 'array'::text",
                         name: "ck_transport_trip_logs_lists"

    create_table :transport_attendance_corrections, id: :uuid do |t|
      t.references :transport_trip_passenger, type: :uuid, null: false, foreign_key: true, index: false
      t.string :field, null: false
      t.string :from_value, null: false
      t.string :to_value, null: false
      # Motivo da correção: cifrado.
      t.text :reason, null: false
      t.references :by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :transport_attendance_corrections, :transport_trip_passenger_id, name: "idx_transport_attendance_corrections_passenger"
    add_check_constraint :transport_attendance_corrections,
                         "field::text = ANY (ARRAY[#{quoted(ATTENDANCE_FIELDS)}]::text[]) AND " \
                         "from_value::text = ANY (ARRAY[#{quoted(ATTENDANCE)}]::text[]) AND " \
                         "to_value::text = ANY (ARRAY[#{quoted(ATTENDANCE)}]::text[]) AND from_value::text <> to_value::text",
                         name: "ck_transport_attendance_corrections_values"

    create_table :transport_pending_items, id: :uuid do |t|
      t.references :transport_series, type: :uuid, null: false, foreign_key: true, index: false
      t.date :date, null: false
      t.string :reason, null: false
      t.datetime :resolved_at
      t.datetime :created_at, null: false
    end
    add_index :transport_pending_items, %i[transport_series_id date], unique: true, name: "idx_transport_pending_items_series_date"
    add_check_constraint :transport_pending_items, "reason::text = ANY (ARRAY[#{quoted(PENDING_REASONS)}]::text[])",
                         name: "ck_transport_pending_items_reason"

    create_table :transport_trip_notices, id: :uuid do |t|
      t.references :transport_trip_passenger, type: :uuid, null: false, foreign_key: true, index: false
      t.references :citizen, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.string :event_key, limit: 80, null: false
      t.datetime :departure_at, null: false
      # Rótulo da parada do passageiro no momento do aviso (o último valor
      # avisado; o boarding_changed compara com ele). Não é dado pessoal.
      t.string :boarding_label, limit: 120, null: false
      t.boolean :sms, null: false, default: false
      t.datetime :read_at
      t.datetime :created_at, null: false
    end
    add_index :transport_trip_notices, %i[transport_trip_passenger_id citizen_id kind event_key], unique: true,
                                                                                               name: "idx_transport_trip_notices_once"
    add_index :transport_trip_notices, %i[citizen_id created_at], name: "idx_transport_trip_notices_citizen"
    add_check_constraint :transport_trip_notices, "kind::text = ANY (ARRAY[#{quoted(NOTICE_KINDS)}]::text[])",
                         name: "ck_transport_trip_notices_kind"
  end

  def create_tfd
    create_table :tfd_cases, id: :uuid do |t|
      t.references :patient, type: :uuid, null: false, foreign_key: true, index: false
      t.references :consultation, type: :uuid, foreign_key: true, index: false
      t.references :regulation_request, type: :uuid, foreign_key: true, index: false
      t.references :requester_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.string :requester_cbo, limit: 6, null: false
      # Laudo (JSON: SIGTAP, CID, justificativa, acompanhante, modal): cifrado.
      t.text :report, null: false
      t.references :transport_destination, type: :uuid, null: false, foreign_key: true, index: false
      t.references :care_provider, type: :uuid, foreign_key: true, index: false
      t.datetime :appointment_at
      t.jsonb :inpatient_stays, null: false, default: []
      t.string :status, null: false, default: "draft"
      t.datetime :submitted_at
      t.datetime :decided_at
      t.integer :version, null: false, default: 1
      t.timestamps
    end
    add_index :tfd_cases, %i[status submitted_at], name: "idx_tfd_cases_queue"
    add_index :tfd_cases, :patient_id, name: "idx_tfd_cases_patient"
    add_index :tfd_cases, %i[requester_user_id updated_at], name: "idx_tfd_cases_requester"
    add_check_constraint :tfd_cases, "status::text = ANY (ARRAY[#{quoted(TFD_STATUSES)}]::text[])", name: "ck_tfd_cases_status"
    add_check_constraint :tfd_cases, "num_nonnulls(consultation_id, regulation_request_id) >= 1", name: "ck_tfd_cases_origin"
    add_check_constraint :tfd_cases, "(status::text = 'draft'::text) = (submitted_at IS NULL)", name: "ck_tfd_cases_submitted"
    add_check_constraint :tfd_cases, "requester_cbo::text ~ '^[0-9]{6}$'::text AND version >= 1 AND jsonb_typeof(inpatient_stays) = 'array'::text",
                         name: "ck_tfd_cases_domains"
    add_foreign_key :transport_trip_passengers, :tfd_cases

    create_table :tfd_case_events, id: :uuid do |t|
      t.references :tfd_case, type: :uuid, null: false, foreign_key: true, index: false
      t.string :kind, null: false
      t.references :by_user, type: :uuid, foreign_key: { to_table: :users }, index: false
      # Motivo (devolução, negativa, cancelamento): cifrado.
      t.text :reason
      t.datetime :created_at, null: false
    end
    add_index :tfd_case_events, %i[tfd_case_id created_at], name: "idx_tfd_case_events_case"
    add_check_constraint :tfd_case_events, "kind::text = ANY (ARRAY[#{quoted(TFD_EVENT_KINDS)}]::text[])", name: "ck_tfd_case_events_kind"

    create_table :tfd_legs, id: :uuid do |t|
      t.references :tfd_case, type: :uuid, null: false, foreign_key: true, index: false
      t.string :direction, null: false
      t.string :mode, null: false
      t.date :date, null: false
      t.integer :distance_km, null: false
      t.references :transport_trip_passenger, type: :uuid, foreign_key: true, index: false
      t.references :outbound_leg, type: :uuid, foreign_key: { to_table: :tfd_legs }, index: false
      t.integer :ticket_amount_cents
      # §14 T18: empresa até 120.
      t.string :ticket_carrier, limit: 120
      t.boolean :companion, null: false, default: false
      t.datetime :done_at
      t.datetime :voided_at
      t.string :void_reason
      t.references :created_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.timestamps
    end
    add_index :tfd_legs, %i[tfd_case_id date], name: "idx_tfd_legs_case"
    # Um passageiro da viagem leva a ida e/ou a volta de frota (a viagem é ida e volta; T38); o anulado
    # não conta (a correção no_show → boarded deixa a comissão registrar o trecho de novo).
    add_index :tfd_legs, %i[transport_trip_passenger_id direction], unique: true,
                                                                    where: "transport_trip_passenger_id IS NOT NULL AND voided_at IS NULL",
                                                                    name: "idx_tfd_legs_trip_passenger"
    add_index :tfd_legs, :outbound_leg_id, unique: true, where: "outbound_leg_id IS NOT NULL", name: "idx_tfd_legs_outbound"
    add_check_constraint :tfd_legs,
                         "direction::text = ANY (ARRAY[#{quoted(DIRECTIONS)}]::text[]) AND mode::text = ANY (ARRAY[#{quoted(MODES)}]::text[]) AND " \
                         "distance_km >= 0 AND (ticket_amount_cents IS NULL OR " \
                         "(ticket_amount_cents >= 1 AND ticket_amount_cents <= #{MAX_AMOUNT_CENTS}))",
                         name: "ck_tfd_legs_domains"
    add_check_constraint :tfd_legs,
                         "(mode::text = 'fleet'::text) = (transport_trip_passenger_id IS NOT NULL) AND " \
                         "(mode::text = 'fleet'::text) = (ticket_amount_cents IS NULL) AND " \
                         "(direction::text = 'return'::text) = (outbound_leg_id IS NOT NULL) AND " \
                         "(mode::text <> 'fleet'::text OR NOT companion) AND (outbound_leg_id IS NULL OR outbound_leg_id <> id)",
                         name: "ck_tfd_legs_mode"
    add_check_constraint :tfd_legs,
                         "(voided_at IS NULL) = (void_reason IS NULL) AND " \
                         "(void_reason IS NULL OR void_reason::text = ANY (ARRAY[#{quoted(VOID_REASONS)}]::text[])) AND " \
                         "(voided_at IS NULL OR (done_at IS NULL AND mode::text = 'fleet'::text))",
                         name: "ck_tfd_legs_void"

    create_table :tfd_allowances, id: :uuid do |t|
      t.references :tfd_case, type: :uuid, null: false, foreign_key: true, index: false
      t.references :tfd_leg, type: :uuid, null: false, foreign_key: true, index: false
      t.string :person, null: false
      t.string :kind, null: false
      t.string :sigtap_code, limit: 10, null: false
      t.string :competence, limit: 6, null: false
      t.integer :quantity, null: false
      t.integer :table_cents, null: false
      t.integer :complement_cents, null: false
      t.integer :total_cents, null: false
      t.datetime :created_at, null: false
    end
    add_index :tfd_allowances, %i[tfd_leg_id person kind], unique: true, name: "idx_tfd_allowances_once"
    add_index :tfd_allowances, :tfd_case_id, name: "idx_tfd_allowances_case"
    add_check_constraint :tfd_allowances,
                         "person::text = ANY (ARRAY[#{quoted(PERSONS)}]::text[]) AND kind::text = ANY (ARRAY[#{quoted(ALLOWANCE_KINDS)}]::text[]) AND " \
                         "sigtap_code::text ~ '^[0-9]{10}$'::text AND competence::text ~ #{COMPETENCE}",
                         name: "ck_tfd_allowances_domains"
    add_check_constraint :tfd_allowances,
                         "quantity >= 1 AND table_cents >= 0 AND complement_cents >= 0 AND " \
                         "total_cents = ((table_cents + complement_cents) * quantity)",
                         name: "ck_tfd_allowances_amounts"

    create_table :tfd_payments, id: :uuid do |t|
      t.references :tfd_case, type: :uuid, null: false, foreign_key: true, index: false
      t.date :paid_on, null: false
      t.integer :amount_cents, null: false
      t.string :payment_method, null: false
      t.string :receipt_number, limit: 40, null: false
      t.references :by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
      t.datetime :created_at, null: false
    end
    add_index :tfd_payments, :tfd_case_id, name: "idx_tfd_payments_case"
    add_check_constraint :tfd_payments,
                         "amount_cents >= 1 AND amount_cents <= #{MAX_AMOUNT_CENTS} AND " \
                         "payment_method::text = ANY (ARRAY[#{quoted(PAYMENT_METHODS)}]::text[]) AND char_length(btrim(receipt_number::text)) >= 1",
                         name: "ck_tfd_payments_domains"

    create_table :tfd_accountability, id: :uuid do |t|
      t.references :tfd_case, type: :uuid, null: false, foreign_key: true, index: false
      t.references :exam_file, type: :uuid, null: false, foreign_key: true, index: false
      # Nome do arquivo: cifrado.
      t.text :filename, null: false
      t.datetime :closed_at, null: false
      t.references :closed_by_user, type: :uuid, null: false, foreign_key: { to_table: :users }, index: false
    end
    add_index :tfd_accountability, :tfd_case_id, unique: true, name: "idx_tfd_accountability_case"
    add_index :tfd_accountability, :exam_file_id, unique: true, name: "idx_tfd_accountability_file"
  end

  # Desvio 15 / §14 T11: a linha do BPA aponta a ajuda de custo (única), com o
  # trecho de rastro.
  def change_performed_procedures
    add_reference :performed_procedures, :tfd_allowance, type: :uuid, foreign_key: true, index: false
    add_reference :performed_procedures, :tfd_leg, type: :uuid, foreign_key: true, index: false
    add_index :performed_procedures, :tfd_allowance_id, unique: true, where: "tfd_allowance_id IS NOT NULL",
                                                        name: "idx_performed_procedures_tfd_allowance"
    add_index :performed_procedures, :tfd_leg_id, where: "tfd_leg_id IS NOT NULL", name: "idx_performed_procedures_tfd_leg"
    replace_check :performed_procedures, "ck_performed_procedures_domains",
                  "source::text = ANY (ARRAY[#{quoted(SOURCES)}]::text[]) " \
                  "AND instrument::text = ANY (ARRAY[#{quoted(INSTRUMENTS)}]::text[]) " \
                  "AND character::text = ANY (ARRAY[#{quoted(CHARACTERS)}]::text[]) " \
                  "AND status::text = ANY (ARRAY['recorded'::text, 'cancelled'::text])"
    replace_check :performed_procedures, "ck_performed_procedures_source_ref",
                  "(source::text <> 'attendance'::text OR attendance_id IS NOT NULL) " \
                  "AND (source::text <> 'consultation'::text OR consultation_id IS NOT NULL) " \
                  "AND (source::text <> 'lab_report'::text OR (lab_report_item_id IS NOT NULL AND exam_provider_id IS NOT NULL)) " \
                  "AND (source::text <> 'tfd'::text OR tfd_allowance_id IS NOT NULL)"
  end

  def quoted(list) = list.map { |value| "'#{value}'::text" }.join(", ")

  def replace_check(table, name, expression)
    remove_check_constraint table, name: name
    add_check_constraint table, expression, name: name
  end
end
