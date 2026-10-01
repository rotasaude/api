require "rails_helper"

RSpec.describe Attendances::CheckInEligibility do
  before { Current.city = TEST_CITY_A }
  after { Current.reset; Rails.cache.clear }

  let(:citizen) { Citizen.create!(cpf: "52998224725", phone: "+5541998765432") }
  let(:staff) { User.create!(email_address: "a@cidade.gov.br", password: "senha-segura-123") }

  it "elegível: concluída há até 3 dias e sem atendimento" do
    fresh = completed_web_triage_for(citizen, completed_at: 71.hours.ago)
    expect(described_class.check(fresh)).to eq(:ok)
    expect(described_class.eligible_for(Citizen.where(id: citizen.id))).to eq([fresh])
  end

  it "antiga e já atendida não são elegíveis" do
    old = completed_web_triage_for(citizen, completed_at: 73.hours.ago)
    expect(described_class.check(old)).to eq(:triage_too_old)
    fresh = completed_web_triage_for(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"))
    Attendance.create!(triage: fresh, citizen: fresh.conversation.citizen, health_unit: create_unit,
                       checked_in_by_user: staff, checked_in_at: Time.current, check_in_method: "code")
    expect(described_class.check(fresh)).to eq(:already_checked_in)
  end
  describe "fronteira exata da janela de 72h" do
    include ActiveSupport::Testing::TimeHelpers

    let(:now) { Time.zone.parse("2026-10-01 10:00:00") }
    let(:unit) { create_unit }

    it "concluída há exatamente 3 dias é elegível; um segundo antes disso, não" do
      travel_to(now) do
        edge = completed_web_triage_for(citizen, completed_at: now - 3.days)
        past = completed_web_triage_for(Citizen.create!(cpf: "11144477735", phone: "+5541911112222"),
                                        completed_at: now - 3.days - 1.second)
        expect(described_class.check(edge)).to eq(:ok)
        expect(described_class.check(past)).to eq(:triage_too_old)
        expect(described_class.eligible_for(Citizen.all)).to eq([ edge ])
      end
    end

    it "por código: check-in de triagem concluída há exatamente 3 dias passa" do
      travel_to(now) do
        edge = completed_web_triage_for(citizen, completed_at: now - 3.days)
        code = Citizens::IssueCheckInCode.call(citizen: citizen, triage: edge).payload.fetch(:code)
        result = Attendances::CheckIn.call(cpf: citizen.cpf, code: code, health_unit_id: unit.id,
                                           document_checked: false, by: staff)
        expect(result).to be_ok
        expect(result.payload[:attendance].triage_id).to eq(edge.id)
      end
    end
  end

  describe "revogação (ADR 0026)" do
    let(:triage) { completed_web_triage_for(citizen) }

    it "recusa triagem anonimizada" do
      triage.update_columns(anonymized_at: Time.current)
      expect(described_class.check(triage)).to eq(:triage_not_eligible)
      expect(described_class.eligible_for(Citizen.where(id: citizen.id))).to be_empty
    end

    it "recusa logo depois do COMMIT da revogação, antes do job anonimizar" do
      RevokeConsent.call(conversation: triage.conversation, origin: "web")
      expect(described_class.check(triage.reload)).to eq(:triage_not_eligible)
      expect(described_class.eligible_for(Citizen.where(id: citizen.id))).to be_empty
    end
  end
end
