# spec/models/record_mode_city_tables_spec.rb
require "rails_helper"

# ADR 0028 (spec 2026-10-05 §3.3, §5, §7): o banco da cidade guarda credencial
# cifrada, CNES/INE/CPF/CNS — e garante unicidade e formato onde o modelo não vê.
RSpec.describe "Tabelas da cidade do módulo 16" do
  let(:admin) { staff_with("admin@cidade.gov.br", "municipal_admin") }
  let(:unit) { create_unit }
  def sql(statement) = ApplicationRecord.transaction(requires_new: true) { ApplicationRecord.connection.execute(statement) }

  describe IntegrationCredential do
    let!(:credential) do
      described_class.create!(kind: "ledi", secret: { "username" => "rota", "password" => "segredo-123" },
                              set_by_user: admin, set_at: Time.current)
    end

    it "cifra o segredo e nunca o mostra no inspect" do
      raw = ApplicationRecord.connection.select_value("SELECT secret FROM integration_credentials WHERE id = '#{credential.id}'")
      expect(raw).not_to include("segredo-123")
      expect(credential.reload.password).to eq("segredo-123")
      expect(credential.inspect).not_to include("segredo-123")
    end

    it "uma por kind; kind e status fora da lista são recusados" do
      expect { sql("INSERT INTO integration_credentials (id, kind, secret, set_by_user_id, set_at, created_at, updated_at) " \
                   "VALUES (gen_random_uuid(), 'ledi', 'x', '#{admin.id}', now(), now(), now())") }
        .to raise_error(ActiveRecord::RecordNotUnique)
      expect { sql("UPDATE integration_credentials SET kind = 'rnds'") }.to raise_error(ActiveRecord::StatementInvalid)
      expect { sql("UPDATE integration_credentials SET last_check_status = 'talvez'") }.to raise_error(ActiveRecord::StatementInvalid)
    end

    it "segredo precisa de usuário e senha não vazios" do
      credential.secret = { "username" => "rota", "password" => "" }
      expect(credential).not_to be_valid
    end
  end

  it "CNES da unidade: 7 dígitos, único, normalizado" do
    unit.update!(cnes: "123.456-7")
    expect(unit.reload.cnes).to eq("1234567")
    expect(HealthUnit.new(name: "Outra", kind: "ubs", cnes: "1234567")).not_to be_valid
    expect(HealthUnit.new(name: "Outra", kind: "ubs", cnes: "123")).not_to be_valid
    expect { sql("UPDATE health_units SET cnes = '12'") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "equipe: INE único de 10 dígitos e tipo 70 ou 76; um membro ativo por profissional e equipe" do
    team = HealthTeam.create!(ine: "0001234567", kind: "70", name: "ESF 1", health_unit: unit)
    expect(HealthTeam.new(ine: "0001234567", kind: "76", health_unit: unit)).not_to be_valid
    expect(HealthTeam.new(ine: "1", kind: "70", health_unit: unit)).not_to be_valid
    expect { sql("UPDATE health_teams SET kind = '71'") }.to raise_error(ActiveRecord::StatementInvalid)

    doctor = staff_with("medica@cidade.gov.br", "health_professional")
    link_professional!(doctor, unit)
    professional = doctor.reload.professional
    HealthTeamMember.create!(professional: professional, health_team: team, cbo_code: "225125", started_on: Date.current)
    expect {
      HealthTeamMember.new(professional: professional, health_team: team, cbo_code: "225125", started_on: Date.current)
                      .save!(validate: false)
    }.to raise_error(ActiveRecord::RecordNotUnique)
    expect { sql("UPDATE health_team_members SET ended_on = started_on - 1") }.to raise_error(ActiveRecord::StatementInvalid)
  end

  it "CPF do profissional: dígito verificador, cifrado, único, mascarado" do
    doctor = staff_with("medica@cidade.gov.br", "health_professional")
    link_professional!(doctor, unit)
    professional = doctor.reload.professional
    professional.update!(cpf: "529.982.247-25")
    expect(professional.reload.cpf).to eq("52998224725")
    expect(professional.cpf_masked).to eq("***.982.247-**")
    raw = ApplicationRecord.connection.select_value("SELECT cpf FROM professionals WHERE id = '#{professional.id}'")
    expect(raw).not_to include("52998224725")
    professional.cpf = "52998224724"
    expect(professional).not_to be_valid
    expect(Professional::FIELDS).to include("cpf")
    expect(Professional::SELF_EDITABLE).not_to include("cpf")
  end

  it "CNS do cidadão e o pendente do CADSUS cifrados" do
    citizen = Citizen.create!(cpf: "52998224725", phone: "+5541998765432")
    citizen.update!(cns: "700000000000005", cadsus_pending_cns: "700000000000005")
    row = ApplicationRecord.connection.select_one("SELECT cns, cadsus_pending_cns FROM citizens WHERE id = '#{citizen.id}'")
    expect(row.values.join).not_to include("700000000000005")
    expect(citizen.reload.cns_masked).to eq("*** **** **** 0005")
  end
end
