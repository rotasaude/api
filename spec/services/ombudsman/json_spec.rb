require "rails_helper"

# Módulo 33 (ADR 0051; contrato §5, §8; Q2, Q4, Q24, Q34): formas JSON da equipe.
RSpec.describe Ombudsman::Json do
  let(:today) { Date.new(2026, 11, 11) }
  let(:settings) { OmbudsmanSetting.new }
  let(:technician) { ombudsman_staff! }

  def detail(manifestation, viewer: ombudsman!)
    described_class.detail(OmbudsmanManifestation.find(manifestation.id), viewer: viewer, settings: settings, today: today)
  end

  describe "subject e destination (Q34)" do
    it "subassunto leva o pai; assunto de primeiro nível, parent nulo" do
      leaf = subject_leaf!
      expect(described_class.subject(leaf)).to eq(id: leaf.id, name: leaf.name, parent: { id: leaf.parent.id, name: leaf.parent.name })
      expect(described_class.subject(leaf.parent)).to eq(id: leaf.parent.id, name: leaf.parent.name, parent: nil)
      expect(described_class.subject(nil)).to be_nil
    end

    it "destination: setor ou unidade" do
      department = department!
      unit = HealthUnit.create!(name: "UBS Json #{SecureRandom.hex(2)}", kind: "ubs", active: true)
      m = raw_manifestation!
      by_department = OmbudsmanForwarding.create!(ombudsman_manifestation: m, department: department, extract: "x" * 20, due_on: today,
                                                  state: "pending", created_by_user: technician)
      by_unit = OmbudsmanForwarding.create!(ombudsman_manifestation: m, health_unit: unit, extract: "x" * 20, due_on: today,
                                            state: "pending", created_by_user: technician)
      expect(described_class.destination(by_department)).to eq(kind: "department", id: department.id, name: department.name)
      expect(described_class.destination(by_unit)).to eq(kind: "health_unit", id: unit.id, name: unit.name)
    end
  end

  describe "identidade (§8, Q24, U1)" do
    it "identified com cidadão: nome, CPF e telefone mascarados; sem contact" do
      citizen = web_citizen!
      identity = detail(raw_manifestation!(citizen: citizen))[:identity]
      expect(identity).to eq(name: nil, cpf_masked: citizen.cpf_masked, phone_masked: CitizenIdentity::Phone.mask(citizen.phone))
    end

    it "o nome declarado (U1) vale sobre o do cidadão" do
      citizen = web_citizen!
      identity = detail(raw_manifestation!(citizen: citizen, manifestant_name: "Maria Declarada"))[:identity]
      expect(identity[:name]).to eq("Maria Declarada")
    end

    it "identified sem cidadão (registro da equipe): manifestant_*, CPF mascarado e contact" do
      m = raw_manifestation!(channel: "phone", manifestant_name: "João da Silva", manifestant_cpf: "52998224725", manifestant_contact: "joao@exemplo.com")
      expect(detail(m)).to include(identity_available: true,
                                   identity: { name: "João da Silva", cpf_masked: "***.982.247-**", phone_masked: nil, contact: "joao@exemplo.com" })
    end

    it "preserved e anonymous: 'preserved', e nada de nome, CPF, telefone ou contato no JSON" do
      citizen = web_citizen!
      preserved = raw_manifestation!(citizen: citizen, identification_mode: "preserved", manifestant_name: "Nome Secreto")
      anonymous = raw_manifestation!(kind: "report", identification_mode: "anonymous")
      [ preserved, anonymous ].each do |m|
        json = detail(m)
        expect(json[:identity]).to eq("preserved")
        expect(json.to_json).not_to include("Nome Secreto", citizen.cpf, citizen.cpf_masked, "*****-", citizen.phone)
      end
      expect(detail(preserved)).to include(identity_available: true, can_open_identity: true)
      expect(detail(preserved, viewer: technician)).to include(can_open_identity: false)
      expect(detail(anonymous)).to include(identity_available: false, can_open_identity: false)
    end
  end

  describe "eventos (Q4)" do
    it "actor_name só para staff; cidadão e sistema, nulo; o texto some quando não há" do
      m = raw_manifestation!
      staff = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "classified", actor: "staff", actor_user: technician, data: { "a" => 1 })
      citizen = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "received", actor: "citizen", text: "Olá", visible_to_citizen: true)
      system = OmbudsmanEvent.create!(ombudsman_manifestation: m, kind: "archived", actor: "system")

      expect(described_class.event(staff)).to eq(id: staff.id, kind: "classified", actor: "staff", actor_name: technician.email_address,
                                                 at: staff.created_at.iso8601, data: { "a" => 1 }, visible_to_citizen: false)
      expect(described_class.event(citizen)).to include(actor: "citizen", actor_name: nil, text: "Olá", visible_to_citizen: true)
      expect(described_class.event(system)).not_to have_key(:text)
      expect(described_class.event(system)).to include(actor_name: nil)
    end
  end

  describe "list_item e detail" do
    it "list_item traz prazo, cor e encaminhamentos pendentes" do
      m = raw_manifestation!(urgent: true)
      item = described_class.list_item(m, settings, today, { m.id => 2 })
      expect(item).to include(id: m.id, protocol: m.protocol, state: "received", urgent: true, channel: "web", subject: nil, health_unit: nil,
                              due_on: (m.cycle_started_on + 15).iso8601, color: "green", pending_forwardings: 2)
      expect(described_class.list_item(m, settings, today, {})[:pending_forwardings]).to eq(0)
    end

    it "anexos saem sem o nome do arquivo (Q2)" do
      m = raw_manifestation!
      attachment = raw_attachment!(manifestation: m, filename: "segredo-do-cidadao.png")
      json = detail(m)
      expect(json[:attachments]).to eq([ { id: attachment.id, uploaded_by: "citizen" } ])
      expect(json.to_json).not_to include("segredo-do-cidadao")
    end

    it "encaminhamentos com extrato e resposta; pedido de reabertura do ciclo mais recente" do
      m = raw_manifestation!(state: "forwarded")
      department = department!
      OmbudsmanForwarding.create!(ombudsman_manifestation: m, department: department, extract: "Extrato do caso para o setor.", due_on: today + 3,
                                  state: "pending", created_by_user: technician)
      json = detail(m)
      expect(json[:forwardings].sole).to include(extract: "Extrato do caso para o setor.", state: "pending", color: "yellow",
                                                 destination: { kind: "department", id: department.id, name: department.name })
      expect(json[:pending_forwardings]).to eq(1)
      expect(json[:reopen_request]).to be_nil
    end
  end
end
