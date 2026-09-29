require "rails_helper"
require Rails.root.join("db/city_migrate/20260928100001_create_territory.rb").to_s

# F-11.1: o down() da migração de cidade 20260928100001 desfaz tudo o que o up()
# cria, e o up() seguinte restaura o mesmo schema (tabelas, colunas, índices,
# constraints, função e trigger) — com o trigger de bairro imutável da triagem
# de volta em ação.
#
# O DDL do Postgres é transacional: down e up rodam na conexão de TEST_CITY_A
# dentro de um savepoint desfeito no fim (além da própria transação de fixture),
# então o banco de teste compartilhado nunca fica alterado. Por isso o retrato
# do schema é lido pela MESMA conexão (catálogo), não por uma conexão nova como
# em spec/services/city_schema_spec.rb — outra sessão não enxergaria o DDL.
RSpec.describe "Migração de cidade 20260928100001 (CreateTerritory): down e up" do
  let(:new_tables) { %w[neighborhoods neighborhood_coverages] }
  let(:new_columns) do
    [
      %w[health_units address_street], %w[health_units address_number], %w[health_units address_complement],
      %w[health_units address_zip], %w[health_units neighborhood_id], %w[citizens neighborhood_id],
      %w[triages neighborhood_id]
    ]
  end
  let(:new_indexes) do
    %w[
      idx_neighborhoods_name_ci idx_neighborhoods_seed_key idx_neighborhood_coverages_pair
      index_neighborhood_coverages_on_health_unit_id index_health_units_on_neighborhood_id
      index_citizens_on_neighborhood_id idx_triages_neighborhood_created
    ]
  end
  let(:new_checks) { %w[ck_neighborhoods_name ck_neighborhoods_source ck_health_units_address_zip] }

  def conn = ApplicationRecord.connection

  def migrate(direction)
    ActiveRecord::Migration.suppress_messages { CreateTerritory.new.exec_migration(conn, direction) }
    [ Neighborhood, NeighborhoodCoverage, HealthUnit, Citizen, Triage ].each(&:reset_column_information)
  end

  def rows(sql) = conn.select_rows(sql)

  # Retrato do schema inteiro da cidade, pela conexão do exemplo. Colunas sem
  # ordinal: o down/up recoloca as colunas no fim da tabela, e isso não é
  # mudança de schema que importe.
  def fingerprint
    ignored = "('schema_migrations', 'ar_internal_metadata')"
    {
      columns: rows(<<~SQL),
        SELECT table_name, column_name, data_type, character_maximum_length::text, is_nullable, column_default
        FROM information_schema.columns
        WHERE table_schema = 'public' AND table_name NOT IN #{ignored} ORDER BY 1, 2
      SQL
      indexes: rows(<<~SQL),
        SELECT tablename, indexname, indexdef FROM pg_indexes
        WHERE schemaname = 'public' AND tablename NOT IN #{ignored} ORDER BY 1, 2
      SQL
      constraints: rows(<<~SQL),
        SELECT rel.relname, con.conname, pg_get_constraintdef(con.oid)
        FROM pg_constraint con
        JOIN pg_class rel ON rel.oid = con.conrelid
        JOIN pg_namespace ns ON ns.oid = rel.relnamespace
        WHERE ns.nspname = 'public' AND rel.relname NOT IN #{ignored} ORDER BY 1, 2
      SQL
      triggers: rows(<<~SQL),
        SELECT c.relname, t.tgname, pg_get_triggerdef(t.oid)
        FROM pg_trigger t
        JOIN pg_class c ON c.oid = t.tgrelid
        JOIN pg_namespace n ON n.oid = c.relnamespace
        WHERE n.nspname = 'public' AND NOT t.tgisinternal AND c.relname NOT IN #{ignored} ORDER BY 1, 2
      SQL
      functions: rows(<<~SQL)
        SELECT p.proname, pg_get_functiondef(p.oid)
        FROM pg_proc p JOIN pg_namespace n ON n.oid = p.pronamespace
        WHERE n.nspname = 'public' AND p.prokind = 'f' ORDER BY 1, 2
      SQL
    }
  end

  # FKs do módulo 11: as duas de neighborhood_coverages e as três *.neighborhood_id.
  def territory_fks(fp)
    fp[:constraints].select do |(table, _name, defn)|
      defn.start_with?("FOREIGN KEY") && "#{table} #{defn}".include?("neighborhood")
    end
  end

  def in_rolled_back_savepoint
    ApplicationRecord.transaction(requires_new: true) do
      yield
      raise ActiveRecord::Rollback
    end
  ensure
    [ Neighborhood, NeighborhoodCoverage, HealthUnit, Citizen, Triage ].each(&:reset_column_information)
  end

  it "down remove tudo o que up cria; up seguinte restaura o schema idêntico e o trigger volta a recusar" do
    in_rolled_back_savepoint do
      before = fingerprint
      # Sanidade: o retrato inicial tem mesmo tudo o que a migração cria.
      expect(before[:columns].map { _1.first(2) }).to include(*new_columns)
      expect(before[:indexes].map(&:second)).to include(*new_indexes)
      expect(before[:constraints].map(&:second)).to include(*new_checks)
      expect(territory_fks(before).size).to eq(5) # coverages→neighborhoods, coverages→health_units, 3 *.neighborhood_id
      expect(before[:triggers].map(&:second)).to include("triages_neighborhood_immutable")
      expect(before[:functions].map(&:first)).to include("rota_triage_neighborhood_guard")

      migrate(:down)
      down = fingerprint

      expect(conn.tables & new_tables).to be_empty
      expect(down[:columns].map { _1.first(2) } & new_columns).to be_empty
      expect(down[:indexes].map(&:second) & new_indexes).to be_empty
      expect(down[:constraints].map(&:second) & new_checks).to be_empty
      expect(territory_fks(down)).to be_empty
      expect(down[:triggers].map(&:second)).not_to include("triages_neighborhood_immutable")
      expect(down[:functions].map(&:first)).not_to include("rota_triage_neighborhood_guard")
      # O down só tira o que é do módulo 11: o resto do schema segue intacto.
      untouched = lambda do |fp|
        fp.transform_values do |list|
          list.reject do |row|
            row.join(" ").include?("neighborhood") || row.first(2).in?(new_columns) || row.second.in?(new_checks)
          end
        end
      end
      expect(untouched.call(down)).to eq(untouched.call(before))

      migrate(:up)

      expect(fingerprint).to eq(before)

      # O trigger restaurado continua recusando trocar o bairro da triagem.
      norte = Neighborhood.create!(name: "Norte Migração #{SecureRandom.hex(3)}", source: "manual")
      sul = Neighborhood.create!(name: "Sul Migração #{SecureRandom.hex(3)}", source: "manual")
      triage = territory_triage!(norte)
      expect do
        ApplicationRecord.transaction(requires_new: true) { triage.update_columns(neighborhood_id: sul.id) }
      end.to raise_error(ActiveRecord::StatementInvalid, /neighborhood_id never changes after insert/)
      expect(triage.reload.neighborhood_id).to eq(norte.id)
    end
  end
end
