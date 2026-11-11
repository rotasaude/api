require "rails_helper"

# Módulo 33 (ADR 0051; contrato §1, §6): papéis e destinos. O respondente só
# alcança o destino de uma linha ativa E enquanto tem o papel ativo.
RSpec.describe Ombudsman::Access do
  let(:department) { department! }
  let(:unit) { HealthUnit.create!(name: "UBS Acesso #{SecureRandom.hex(2)}", kind: "ubs", active: true) }

  def revoke_role!(user, role) = Membership.active.where(user: user, role: role).update_all(revoked_at: Time.current)

  it "ombudsman é staff (faz tudo do técnico); o técnico não é ombudsman" do
    expect(described_class.staff?(ombudsman!)).to be(true)
    expect(described_class.ombudsman?(ombudsman!)).to be(true)
    technician = ombudsman_staff!
    expect(described_class.staff?(technician)).to be(true)
    expect(described_class.ombudsman?(technician)).to be(false)
  end

  it "respondente, administrador e usuário sem papel não são staff; nil nunca tem papel" do
    responder = responder!(department)
    expect(described_class.responder?(responder)).to be(true)
    expect(described_class.staff?(responder)).to be(false)
    expect(described_class.staff?(ombudsman_admin!)).to be(false)
    expect(described_class.admin?(ombudsman_admin!)).to be(true)
    expect(described_class.staff?(nil)).to be(false)
    expect(described_class.responder?(User.create!(email_address: "sem-papel@cidade.gov.br", password: "senha-segura-123"))).to be(false)
  end

  it "config_reader?: administrador, técnico e ouvidor; respondente não" do
    expect([ ombudsman_admin!, ombudsman_staff!, ombudsman! ].map { |u| described_class.config_reader?(u) }).to all(be(true))
    expect(described_class.config_reader?(responder!(department))).to be(false)
  end

  describe ".destinations" do
    it "respondente sem linha ativa não tem destino" do
      user = staff_with("sem-linha@cidade.gov.br", "ombudsman_responder")
      expect(described_class.destinations(user)).to eq(department_ids: [], health_unit_ids: [])
    end

    it "linha ativa dá o destino (setor e unidade)" do
      user = responder!(department)
      OmbudsmanResponder.create!(user: user, health_unit: unit, created_by_user: ombudsman!)
      expect(described_class.destinations(user)).to eq(department_ids: [ department.id ], health_unit_ids: [ unit.id ])
    end

    it "linha desligada não conta" do
      user = responder!(department)
      OmbudsmanResponder.find_by!(user: user).update!(active: false)
      expect(described_class.destinations(user)).to eq(department_ids: [], health_unit_ids: [])
    end

    it "linha ativa com o papel revogado não conta" do
      user = responder!(department)
      revoke_role!(user, "ombudsman_responder")
      expect(described_class.destinations(user)).to eq(department_ids: [], health_unit_ids: [])
    end
  end

  describe ".responder_ids_for" do
    it "devolve os respondentes ativos do setor ou da unidade, sem repetir" do
      first = responder!(department)
      second = responder!(department)
      other = responder!(unit)
      expect(described_class.responder_ids_for(department_id: department.id)).to contain_exactly(first.id, second.id)
      expect(described_class.responder_ids_for(health_unit_id: unit.id)).to contain_exactly(other.id)
    end

    it "fora: usuário desativado, linha desligada e papel revogado" do
      kept = responder!(department)
      deactivated = responder!(department)
      switched_off = responder!(department)
      revoked = responder!(department)
      deactivated.update!(deactivated_at: Time.current)
      OmbudsmanResponder.find_by!(user: switched_off).update!(active: false)
      revoke_role!(revoked, "ombudsman_responder")
      expect(described_class.responder_ids_for(department_id: department.id)).to eq([ kept.id ])
    end

    it "sem destino, vazio" do
      expect(described_class.responder_ids_for).to eq([])
    end
  end
end
