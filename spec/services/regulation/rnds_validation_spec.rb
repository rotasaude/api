require "rails_helper"

# Módulo 26c, Task 8 (Valor 4; Q9, Q15, Q22, Q23; pré-voo M16): a conferência antes do
# envio. Pura sobre os fatos; todos os motivos de uma vez, na ordem do
# BLOCK_REASONS. O SIGTAP vigente (Q9) é lido do banco pelo RiraFacts.
RSpec.describe Regulation::RndsValidation, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }

  def facts(**over)
    Regulation::RiraFacts.new(**{
      patient_cpf: valid_cpf(903), patient_cns: nil, requester_cnes: "2345678", author_cnes: "1234567", requester_id: "2926",
      target_type: "procedure", target_code: "0401010074", sigtap: "0401010074", sigtap_valid: true,
      performer_cnes: "3456789", performer_cbo: "225250", priority: "routine", cid10: "I10", ciap2: nil,
      requested_at: now - 10.days, authorized_at: now - 5.days, scheduled_at: now + 3.days,
      scheduled_ends_at: now + 3.days + 20.minutes,
      absences: [ Regulation::RiraFacts::Slot.new(starts_at: now - 4.days, ends_at: now - 4.days + 20.minutes, cnes: "4567890") ],
      status_times: {}, own_network: true
    }.merge(over))
  end

  def target(status) = Regulation::RndsStatus::Target.new(status: status, at: now)
  def check(f, status = "booked") = described_class.call(facts: f, status: target(status))

  it "documento completo passa em todas as situações" do
    Regulation::RndsCatalog::MIRA_STATUSES.each { |status| expect(check(facts, status)).to eq(:ok), status }
  end

  it "missing_diagnosis: sem CID e sem CIAP; só o CIAP passa" do
    expect(check(facts(cid10: nil, ciap2: nil))).to eq([ :blocked, %w[missing_diagnosis] ])
    expect(check(facts(cid10: nil, ciap2: "K86"))).to eq(:ok)
  end

  it "requester_unit_without_cnes" do
    expect(check(facts(requester_cnes: nil), "pending")).to eq([ :blocked, %w[requester_unit_without_cnes] ])
  end

  it "performer_without_cnes só em booked e attended" do
    expect(check(facts(performer_cnes: nil), "booked")).to eq([ :blocked, %w[performer_without_cnes] ])
    expect(check(facts(performer_cnes: nil), "attended")).to eq([ :blocked, %w[performer_without_cnes] ])
    %w[pending cancelled absence returned-to-requester excluded].each do |status|
      expect(check(facts(performer_cnes: nil), status)).to eq(:ok), status
    end
  end

  it "performer_without_cnes no absence da rede própria: a unidade do no_show sem CNES (Q22)" do
    no_cnes = [ Regulation::RiraFacts::Slot.new(starts_at: now - 4.days, ends_at: now - 4.days + 20.minutes, cnes: nil) ]
    expect(check(facts(absences: no_cnes), "absence")).to eq([ :blocked, %w[performer_without_cnes] ])
  end

  it "external_absence_without_schedule: a falta do pedido externo fica parada (Q22)" do
    external = facts(own_network: false, absences: [])
    expect(check(external, "absence")).to eq([ :blocked, %w[external_absence_without_schedule] ])
    expect(check(external, "booked")).to eq(:ok)
    expect(check(facts, "absence")).to eq(:ok)
  end

  it "patient_without_cpf_or_cns; só o CNS passa" do
    expect(check(facts(patient_cpf: nil))).to eq([ :blocked, %w[patient_without_cpf_or_cns] ])
    expect(check(facts(patient_cpf: nil, patient_cns: valid_cns(903)))).to eq(:ok)
  end

  it "performer_cbo_missing: booked/attended com SIGTAP dos grupos 03 e 04" do
    expect(check(facts(performer_cbo: nil), "booked")).to eq([ :blocked, %w[performer_cbo_missing] ])
    expect(check(facts(performer_cbo: nil, sigtap: "0301010072", target_code: "0301010072"), "attended"))
      .to eq([ :blocked, %w[performer_cbo_missing] ])
  end

  it "procedimento do grupo 02 agendado sem CBO passa" do
    expect(check(facts(performer_cbo: nil, sigtap: "0209010037", target_code: "0209010037"), "booked")).to eq(:ok)
  end

  it "pending sem executante não pede CBO nem CNES do executante" do
    expect(check(facts(performer_cbo: nil, performer_cnes: nil), "pending")).to eq(:ok)
  end

  it "specialty_without_sigtap só no alvo specialty (M16)" do
    expect(check(facts(target_type: "specialty", target_code: "225120", sigtap: "0305010107", sigtap_valid: false), "pending"))
      .to eq([ :blocked, %w[specialty_without_sigtap] ])
    expect(check(facts(sigtap_valid: false), "pending")).to eq(:ok)
  end

  it "missing_priority (Q15): sem cor decidida nem sugerida, nada é enviado" do
    expect(check(facts(priority: nil), "pending")).to eq([ :blocked, %w[missing_priority] ])
  end

  it "os motivos novos ficam no fim do BLOCK_REASONS, nesta ordem (Q23)" do
    expect(Regulation::RndsCatalog::BLOCK_REASONS.last(2)).to eq(%w[missing_priority external_absence_without_schedule])
  end

  it "motivos juntos numa lista, na ordem do BLOCK_REASONS" do
    all = facts(cid10: nil, requester_cnes: nil, performer_cnes: nil, patient_cpf: nil, performer_cbo: nil,
                target_type: "specialty", target_code: "225120", sigtap: "0401010074", sigtap_valid: false, priority: nil)
    expect(check(all)).to eq([ :blocked, Regulation::RndsCatalog::BLOCK_REASONS - %w[external_absence_without_schedule] ])
    absent = facts(cid10: nil, own_network: false, absences: [], priority: nil)
    expect(check(absent, "absence")).to eq([ :blocked, %w[missing_diagnosis missing_priority external_absence_without_schedule] ])
    expect(check(facts(cid10: nil, patient_cpf: nil))).to eq([ :blocked, %w[missing_diagnosis patient_without_cpf_or_cns] ])
  end

  it "aceita o passo { status, at } e só o código" do
    expect(described_class.call(facts: facts(performer_cnes: nil), status: { "status" => "booked", "at" => now.iso8601 }))
      .to eq([ :blocked, %w[performer_without_cnes] ])
    expect(described_class.call(facts: facts(performer_cnes: nil), status: "pending")).to eq(:ok)
  end

  describe "SIGTAP da especialidade (Q9), lido pelo RiraFacts" do
    before do
      travel_to now
      regulation_city!
    end

    it "SIGTAP configurado não regulável → specialty_without_sigtap; o padrão vigente passa" do
      request = regulation_request!(unit: create_unit("UBS #{SecureRandom.hex(2)}", cnes: regulation_cnes))
      settings = RegulationRndsSetting.current
      read = -> { Regulation::RiraFacts.for(request: request.reload, settings: settings.reload, credential: nil) }
      expect(described_class.call(facts: read.call, status: target("pending"))).to eq(:ok)
      settings.update!(specialty_sigtap: { "225120" => "0305010107" }) # só APAC: não regulável
      expect(described_class.call(facts: read.call, status: target("pending"))).to eq([ :blocked, %w[specialty_without_sigtap] ])
    end

    it "SIGTAP fora da competência de hoje → specialty_without_sigtap" do
      request = regulation_request!(unit: create_unit("UBS #{SecureRandom.hex(2)}", cnes: regulation_cnes))
      facts_then = Regulation::RiraFacts.for(request: request, settings: RegulationRndsSetting.current, credential: nil,
                                             today: Date.new(1999, 1, 1)) # antes da competência mais antiga da semente
      expect(described_class.call(facts: facts_then, status: target("pending"))).to eq([ :blocked, %w[specialty_without_sigtap] ])
    end
  end
end
