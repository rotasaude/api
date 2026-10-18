require "rails_helper"

# Desvio 10 / Review: a reprovação do CIQ e a liberação do mesmo analito no
# mesmo aparelho ao mesmo tempo, nas duas ordens. Aparelho FOR UPDATE (CIQ)
# × FOR SHARE (liberação, antes da requisição): sem deadlock e sem buraco —
# ou o item não sai (qc_blocked), ou sai e entra na revisão do bloqueio.
RSpec.describe "Bloqueio do CIQ × liberação sob disputa" do
  include LabQcHelpers

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
    allow(ClinicalTerms::SigtapExams).to receive(:find).and_return(Struct.new(:competence).new(Time.zone.today.strftime("%Y%m")))
    # Sem fixture transacional a plataforma não é tocada: o interruptor vem de um dublê.
    allow(Lab::Gate).to receive(:qc_usable?).and_return(true)
    @rows = in_city do
      @empty = empty_tables
      provider = lab_provider!
      lead = lab_releaser!(provider, lead: true)
      scenario = qc_scenario!(provider: provider)
      staff = lab_staff!
      qc_value!(scenario, "Nível 1", 0.1, by: staff, now: 2.minutes.ago)
      qc_value!(scenario, "Nível 2", 0.2, by: staff, now: 2.minutes.ago + 1)
      Lab::Qc::OpenRun.call(instrument: scenario.instrument, by: staff, now: 1.minute.ago)
      req = received_requisition!(provider: provider, exams: [ scenario.exam ])
      item = type!(req.items.first, { glicose: "98" }, by: staff)
      { req_id: req.id, item_id: item.id, lead: lead.id, staff: staff.id, instrument_id: scenario.instrument.id, lot_id: scenario.lot.id }
    end
  end

  after do
    3.times { release_gate << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
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

  def release
    user = User.find(@rows[:lead])
    Lab::Release.call(requisition: LabRequisition.find(@rows[:req_id]), item_ids: [ @rows[:item_id] ], signature: "advanced",
                      totp: ROTP::TOTP.new(user.otp_secret).now, by: user)
  end

  def reject
    Lab::Qc::RecordValue.call(instrument: LabInstrument.find(@rows[:instrument_id]), lot: LabQcLot.find(@rows[:lot_id]), level: "Nível 1",
                              analyte_key: "glicose", value: BigDecimal("118"), source: "typed", by: User.find(@rows[:staff]))
  end

  # A primeira segura a transação aberta até o release_gate; a segunda espera a trava.
  def race(first, second)
    holding = Queue.new
    first_out = Queue.new
    threads << Thread.new do
      in_city do
        ApplicationRecord.transaction do
          first_out << first.call
          holding << true
          release_gate.pop(timeout: 10) or raise "timeout"
        end
      end
    end
    holding.pop(timeout: 10) or raise "timeout"
    second_out = Queue.new
    threads << Thread.new { in_city { second_out << second.call } }
    sleep 0.3
    release_gate << true
    [ first_out.pop(timeout: 10), second_out.pop(timeout: 10) ]
  end

  it "reprovação primeiro: a liberação espera o aparelho e leva qc_blocked" do
    first, second = race(-> { reject }, -> { release })
    expect(first).to be_ok
    expect(first.payload[:block]).to be_present
    expect(second.reason).to eq(:qc_blocked)
    expect(second.details[:items].map { |i| i[:item_id] }).to eq([ @rows[:item_id] ])
    in_city do
      expect(LabRequisitionItem.find(@rows[:item_id]).status).to eq("typed")
      expect(LabReportItem.where(lab_requisition_item_id: @rows[:item_id])).to be_empty
    end
  end

  it "liberação primeiro: a reprovação espera, o item sai e entra na revisão do bloqueio" do
    first, second = race(-> { release }, -> { reject })
    expect(first).to be_ok
    expect(second).to be_ok
    in_city do
      block = LabQcBlock.active.sole
      expect(LabRequisitionItem.find(@rows[:item_id]).status).to eq("released")
      expect(LabQcReviewItem.where(lab_qc_block: block).pluck(:lab_requisition_item_id)).to eq([ @rows[:item_id] ])
    end
  end
end
