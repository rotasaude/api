require "rails_helper"

# C-E35 (revisão final I1/I2): a FK de referência e de versão do exame toma
# FOR KEY SHARE no aparelho. Se o comando travasse o lote (ou o exame) antes do
# aparelho, quem já tem o aparelho FOR UPDATE (valor de controle, lote em uso)
# e espera o lote (ou o exame) fecharia um ciclo: deadlock → 500. A primeira
# thread segura o aparelho como o valor/lote em uso fazem e só então segue;
# a segunda roda o comando. Com aparelho → lote/exame, ela só espera.
RSpec.describe "Ordem de travas aparelho primeiro sob disputa" do
  self.use_transactional_tests = false

  let(:release_gate) { Queue.new }
  let(:threads) { [] }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  def empty_tables
    connection = ApplicationRecord.connection
    connection.tables.reject { |t| %w[schema_migrations ar_internal_metadata].include?(t) }
              .select { |t| connection.select_value("SELECT NOT EXISTS (SELECT 1 FROM #{connection.quote_table_name(t)})") }
  end

  before do
    @rows = in_city do
      @empty = empty_tables
      provider = lab_provider!
      scenario = qc_scenario!(provider: provider)
      supply = LabSupply.create!(exam_provider: provider, name: "Glicose GOD-PAP", kind: "reagent", unit: "kit", tests_per_package: 500,
                                 minimum_stock: 1, expiry_alert_days: 30, lab_exam_ids: [ scenario.exam.id ])
      supply_lot = Lab::Inventory::ReceiveLot.call({ "supply_id" => supply.id, "lot_number" => "GL1", "expires_on" => (Time.zone.today + 90).iso8601,
                                                     "supplier" => "Distribuidora", "origin" => "purchase", "quantity" => 2 },
                                                   by: lab_staff!).payload[:lot]
      { instrument_id: scenario.instrument.id, lot_id: scenario.lot.id, exam_id: scenario.exam.id, supply_lot_id: supply_lot.id,
        staff: lab_staff!.id, lead: lab_releaser!(provider, lead: true).id, admin: lab_admin!.id }
    end
  end

  after do
    3.times { release_gate << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError, ScriptError # join relança o erro da thread; a limpeza abaixo tem de rodar sempre
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        @empty.to_a.each { |table| connection.execute("DELETE FROM #{connection.quote_table_name(table)}") }
      end
    end
  end

  def guarded
    yield
  rescue StandardError => e
    e
  end

  # A primeira trava o aparelho FOR UPDATE (como o valor de controle e o lote
  # em uso fazem antes de tudo), espera a segunda chegar e roda o comando dela.
  def race(holder_command, second)
    holding = Queue.new
    first_out = Queue.new
    threads << Thread.new do
      first_out << guarded do
        in_city do
          ApplicationRecord.transaction do
            LabInstrument.lock.find(@rows[:instrument_id])
            holding << true
            release_gate.pop(timeout: 10) or raise "timeout"
            holder_command.call
          end
        end
      end
    end
    holding.pop(timeout: 10) or raise "timeout"
    second_out = Queue.new
    threads << Thread.new { second_out << guarded { in_city { second.call } } }
    sleep 0.3
    release_gate << true
    [ first_out.pop(timeout: 15), second_out.pop(timeout: 15) ]
  end

  def record_value
    Lab::Qc::RecordValue.call(instrument: LabInstrument.find(@rows[:instrument_id]), lot: LabQcLot.find(@rows[:lot_id]), level: "Nível 1",
                              analyte_key: "glicose", value: BigDecimal("101"), source: "typed", by: User.find(@rows[:staff]))
  end

  def expect_ok(*results)
    results.each do |result|
      expect(result).not_to be_a(Exception), -> { "#{result.class}: #{result.message if result.is_a?(Exception)}" }
      expect(result).to be_a(Result)
      expect(result).to be_ok, -> { "falhou: #{result.reason}" }
    end
  end

  it "referência da bula × valor de controle do mesmo aparelho e lote: sem deadlock" do
    create_target = lambda do
      Lab::Qc::CreateTarget.call({ "lot_id" => @rows[:lot_id], "level" => "Nível 1", "analyte_key" => "glicose", "instrument_id" => @rows[:instrument_id],
                                   "mean" => "101", "sd" => "5", "reason" => "bula nova" }, by: User.find(@rows[:lead]))
    end
    value, target = race(-> { record_value }, create_target)
    expect_ok(value, target)
    in_city do
      expect(LabQcValue.count).to eq(1)
      expect(LabQcTarget.where(lab_qc_lot_id: @rows[:lot_id], level: "Nível 1").maximum(:version)).to eq(2)
    end
  end

  it "aceite da sugestão × valor de controle do mesmo aparelho e lote: sem deadlock" do
    allow(Lab::Qc::Suggestions).to receive(:find) do |lot_id:, level:, analyte_key:, instrument_id:|
      Lab::Qc::Suggestions::Suggestion.new(lot_id: lot_id, level: level, analyte_key: analyte_key, instrument_id: instrument_id,
                                           mean: BigDecimal("100.5"), sd: BigDecimal("4.8"), runs: 20, current_version: 1,
                                           current_source: "package_insert")
    end
    accept = lambda do
      Lab::Qc::AcceptSuggestion.call(lot_id: @rows[:lot_id], level: "Nível 1", analyte_key: "glicose", instrument_id: @rows[:instrument_id],
                                     reason: "20 corridas", by: User.find(@rows[:lead]))
    end
    value, target = race(-> { record_value }, accept)
    expect_ok(value, target)
    in_city { expect(LabQcTarget.where(lab_qc_lot_id: @rows[:lot_id], level: "Nível 1", source: "laboratory").count).to eq(1) }
  end

  it "lote em uso × nova versão do exame ligada ao aparelho: sem deadlock" do
    set_in_use = lambda do
      Lab::Inventory::SetInUse.call(lot_id: @rows[:supply_lot_id], instrument_id: @rows[:instrument_id], lab_exam_id: @rows[:exam_id],
                                    by: User.find(@rows[:staff]))
    end
    create_version = lambda do
      Lab::CreateVersion.call(exam: LabExam.find(@rows[:exam_id]), by: User.find(@rows[:admin]),
                              params: { "method" => "Enzimático (GOD-PAP)", "material" => "Plasma", "container" => "Tubo cinza",
                                        "instrument_test_code" => "GLI", "lab_instrument_id" => @rows[:instrument_id],
                                        "analytes" => LabHelpers::GLUCOSE })
    end
    in_use, version = race(set_in_use, create_version)
    expect_ok(in_use, version)
    in_city do
      expect(LabSupplyInUse.current.where(lab_instrument_id: @rows[:instrument_id]).count).to eq(1)
      expect(LabExam.find(@rows[:exam_id]).current_version.version).to eq(2)
    end
  end
end
