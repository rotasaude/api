require "rails_helper"

# Módulo 32a (ADR 0050, R4; plano, Desvios 5 e 6; contrato §14 Q5, Q21): toda
# tabela da cidade com `patient_id` está numa das três listas da fusão do
# provisório — movida (Urgency::Merge::TABLES), mantida com ele
# (Urgency::Merge::KEPT, as trilhas) ou bloqueante (Urgency::Merge.blocking_tables:
# uma linha do provisório ali recusa a fusão). Tabela nova com paciente nasce
# bloqueante até alguém decidir. Lido do banco de teste (o mesmo schema e os
# mesmos triggers de db/city_triggers.sql da cidade).
RSpec.describe "Tabelas da fusão do paciente provisório" do
  let!(:city) { clinical_city! }
  let(:connection) { ApplicationRecord.connection }

  def patient_tables
    connection.select_values(<<~SQL).sort
      SELECT c.table_name FROM information_schema.columns c
      JOIN information_schema.tables t ON t.table_schema = c.table_schema AND t.table_name = c.table_name
      WHERE c.table_schema = current_schema() AND c.column_name = 'patient_id' AND t.table_type = 'BASE TABLE'
    SQL
  end

  # As funções dos triggers de linha BEFORE UPDATE da tabela (nome e corpo).
  def update_guards(table)
    connection.select_rows(<<~SQL)
      SELECT p.proname, p.prosrc FROM pg_trigger tg
      JOIN pg_class c ON c.oid = tg.tgrelid
      JOIN pg_namespace n ON n.oid = c.relnamespace AND n.nspname = current_schema()
      JOIN pg_proc p ON p.oid = tg.tgfoid
      WHERE c.relname = #{connection.quote(table)} AND NOT tg.tgisinternal
        AND (tg.tgtype & 1) = 1 AND (tg.tgtype & 2) = 2 AND (tg.tgtype & 16) = 16
    SQL
  end

  it "toda tabela com patient_id está em TABLES, em KEPT ou é bloqueante; as listas não se cruzam" do
    tables = Urgency::Merge::TABLES
    kept = Urgency::Merge::KEPT
    blocking = Urgency::Merge.blocking_tables
    expect(tables & kept).to be_empty
    expect(blocking & (tables + kept)).to be_empty
    expect((tables + kept + blocking).sort).to eq(patient_tables)
    expect(tables + kept).to all(satisfy { |table| patient_tables.include?(table) })
    expect(tables).not_to include("citizens", "patients")
    expect(blocking).to include("citizens", "immunizations", "vaccination_record_checks", "individual_registrations")
  end

  it "contrato §14 Q5 e Q21: a lista de problemas, a de medicamentos e a receita externa mudam de dono; as trilhas ficam" do
    expect(Urgency::Merge::TABLES).to include("patient_problems", "patient_medications", "external_prescriptions",
                                              "attendances", "consultations", "clinical_documents", "exam_orders", "exam_results",
                                              "lab_requisitions", "disease_notifications", "regulation_requests", "dispensations",
                                              "performed_procedures")
    expect(Urgency::Merge::KEPT).to contain_exactly("clinical_record_openings", "clinical_record_administrative_reads",
                                                    "patient_profile_divergences")
  end

  # Guardas que só recusam uma transição de status (a troca só de patient_id
  # nunca muda o status): não precisam da marca. Guarda nova numa tabela
  # movida entra aqui só depois de alguém conferir isso.
  def status_only_guards = %w[rota_attendance_screening_close_guard]

  # Cada guarda que recusa (tem RAISE) abre a marca no topo; o genérico
  # rota_reencryption_only só para as tabelas da lista dele.
  it "toda guarda de UPDATE de uma tabela movida chama rota_patient_merge_ok" do
    Urgency::Merge::TABLES.each do |table|
      update_guards(table).each do |name, source|
        next if !source.include?("RAISE EXCEPTION") || status_only_guards.include?(name)

        expect(source).to include("rota_patient_merge_ok"), "#{table}: #{name} sem a marca da fusão"
        next unless name == "rota_reencryption_only"

        allowed = source[/TG_TABLE_NAME IN \(([^)]*)\)/, 1].to_s.scan(/'([a-z_]+)'/).flatten
        expect(allowed).to include(table), "#{table}: fora da lista do rota_reencryption_only"
      end
    end
    # A lista do genérico só tem tabelas movidas (a trilha fica de fora).
    source = connection.select_value("SELECT prosrc FROM pg_proc WHERE proname = 'rota_reencryption_only'")
    allowed = source[/TG_TABLE_NAME IN \(([^)]*)\)/, 1].scan(/'([a-z_]+)'/).flatten
    expect(allowed).to contain_exactly("exam_results", "dispensations", "external_prescriptions")
    expect(allowed - Urgency::Merge::TABLES).to be_empty
  end

  it "a chave única com patient_id de uma tabela movida é de colunas (a detecção de repetido lê as colunas e o predicado)" do
    Urgency::Merge::TABLES.each do |table|
      expect(Urgency::Merge.unique_keys(table)).to all(include(columns: include("patient_id")))
    end
    expect(Urgency::Merge.unique_keys("patient_problems")).to include(include(columns: %w[patient_id terminology code]))
    expect(Urgency::Merge.unique_keys("attendances")).to include(include(columns: %w[patient_id health_unit_id]))
  end

  def code_of(path) = File.readlines(path).reject { |line| line.lstrip.start_with?("#", "--") }.join

  it "a marca rota.patient_merge só é ligada pelo Urgency::Merge.with_marker (e lida nos triggers)" do
    users = Dir[*%w[app/**/*.{rb,rake,erb,sql} lib/**/*.{rb,rake,sql} config/**/*.{rb,yml,rake} db/**/*.{rb,sql}].map { |g| Rails.root.join(g).to_s }]
              .select { |path| code_of(path).include?("rota.patient_merge") }
              .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort
    expect(users).to eq(%w[app/services/urgency/merge.rb db/city_triggers.sql])
    callers = Dir[Rails.root.join("app/**/*.rb").to_s].select { |path| code_of(path).match?(/\bwith_marker\b/) }
                                                      .map { |path| Pathname(path).relative_path_from(Rails.root).to_s }.sort
    expect(callers).to eq(%w[app/services/urgency/merge.rb])
  end
end
