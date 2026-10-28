require "rails_helper"

# Módulo 26a (ADR 0044; contrato §1): quem pode pedir o quê, e a lista do
# enfermeiro (NurseItems).
RSpec.describe CareRegulation::Requesters do
  before { regulation_city! }

  let(:admin) { regulation_admin! }

  def target(type, code) = CareRegulation::Targets.resolve(type: type, code: code).payload.fetch(:target)

  it "kind: pelo prefixo do CBO" do
    expect(described_class.kind("225125")).to eq(:physician)
    expect(described_class.kind("223505")).to eq(:nurse)
    expect(described_class.kind("223208")).to eq(:dentist)
    expect(described_class.kind("322205")).to be_nil
    expect(described_class.kind(nil)).to be_nil
  end

  it "médico pede qualquer especialidade e procedimento" do
    expect(described_class.check(cbo: "225125", target: target("specialty", "225120"))).to eq(:ok)
    expect(described_class.check(cbo: "225125", target: target("procedure", "0209010037"))).to eq(:ok)
    expect(described_class.check(cbo: "225125", target: target("specialty", "223212"))).to eq(:ok)
  end

  it "enfermeiro só o que está na lista municipal" do
    gineco = target("specialty", "225250") # Ginecologia e obstetrícia
    expect(described_class.check(cbo: "223505", target: gineco)).to eq(:cbo_not_allowed)

    expect(CareRegulation::NurseItems.add(target_type: "specialty", target_code: "225250", by: admin)).to be_ok
    expect(described_class.check(cbo: "223505", target: gineco)).to eq(:ok)
    expect(described_class.check(cbo: "223505", target: target("specialty", "225120"))).to eq(:cbo_not_allowed)

    expect(CareRegulation::NurseItems.add(target_type: "procedure", target_code: "0209010037", by: admin)).to be_ok
    expect(described_class.check(cbo: "223505", target: target("procedure", "0209010037"))).to eq(:ok)
    # o mesmo código em outro tipo não vale
    expect(described_class.check(cbo: "223505", target: target("procedure", "0301010072"))).to eq(:cbo_not_allowed)

    expect(CareRegulation::NurseItems.remove(target_type: "specialty", target_code: "225250", by: admin)).to be_ok
    expect(described_class.check(cbo: "223505", target: gineco)).to eq(:cbo_not_allowed)
  end

  it "dentista só especialidade odontológica" do
    expect(described_class.check(cbo: "223208", target: target("specialty", "223212"))).to eq(:ok)
    expect(described_class.check(cbo: "223208", target: target("specialty", "225120"))).to eq(:cbo_not_allowed)
    expect(described_class.check(cbo: "223208", target: target("procedure", "0209010037"))).to eq(:cbo_not_allowed)
  end

  it "outros CBOs nunca pedem" do
    expect(described_class.check(cbo: "322205", target: target("specialty", "225120"))).to eq(:cbo_not_allowed)
    expect(described_class.check(cbo: nil, target: target("specialty", "225120"))).to eq(:cbo_not_allowed)
  end

  describe CareRegulation::NurseItems do
    it "add: alvo inválido → invalid_target; repetido → duplicate_item; publica o evento só com user_id" do
      bad = described_class.add(target_type: "specialty", target_code: "225125", by: admin)
      expect([ bad.reason, bad.details ]).to eq([ :invalid_target, { path: "target_code" } ])
      expect(described_class.add(target_type: "procedure", target_code: "0305010107", by: admin).reason).to eq(:invalid_target)

      added = described_class.add(target_type: "specialty", target_code: "225250", by: admin)
      expect(added.payload.fetch(:item)).to have_attributes(target_type: "specialty", target_code: "225250", created_by_user: admin)
      expect(described_class.add(target_type: "specialty", target_code: "225250", by: admin).reason).to eq(:duplicate_item)
      expect(NurseRequestableItem.count).to eq(1)

      events = DomainEvent.where(name: "care_regulation.settings_changed")
      expect(events.map(&:payload)).to eq([ { "user_id" => admin.id } ])
    end

    it "remove: ausente → not_found; remove mesmo se o alvo deixou de ser regulável" do
      expect(described_class.remove(target_type: "specialty", target_code: "225250", by: admin).reason).to eq(:not_found)
      expect(described_class.remove(target_type: nil, target_code: nil, by: admin).reason).to eq(:not_found)

      NurseRequestableItem.create!(target_type: "procedure", target_code: "0305010107", created_by_user: admin)
      expect(described_class.remove(target_type: "procedure", target_code: "0305010107", by: admin)).to be_ok
      expect(NurseRequestableItem.count).to eq(0)
    end

    it "list: com o nome do alvo, por tipo e nome" do
      described_class.add(target_type: "procedure", target_code: "0209010037", by: admin)
      described_class.add(target_type: "specialty", target_code: "225250", by: admin)
      described_class.add(target_type: "specialty", target_code: "225120", by: admin)
      expect(described_class.list).to eq([
        { target_type: "procedure", target_code: "0209010037", name: "ESOFAGOGASTRODUODENOSCOPIA" },
        { target_type: "specialty", target_code: "225120", name: "Cardiologia" },
        { target_type: "specialty", target_code: "225250", name: CareRegulation::Targets.name_for(type: "specialty", code: "225250") }
      ])
    end
  end
end
