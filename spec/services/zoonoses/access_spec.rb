require "rails_helper"

# Módulo 35b (ADR 0054; contrato §1, Q12; plano, Desvios 1–2): quem faz o quê
# no centro de zoonoses. A equipe é o papel zoonoses_team ou a coordenação do
# 35a; a veterinária é da equipe (Q12: precisa do papel) e tem o perfil CRMV
# completo com vínculo 223305 numa UVZ ativa; o municipal_admin só lê; o
# agente de campo é o ACE ou o ACS no escopo da visita do domicílio, e só o
# ACE coleta.
RSpec.describe Zoonoses::Access, type: :model do
  before { zoonoses_city! }

  describe ".veterinarian?" do
    it "veterinária com o papel, vínculo 223305 na UVZ e CRMV completo → veterinarian?" do
      vet = veterinarian!
      expect(described_class.veterinarian?(vet)).to be(true)
      expect(described_class.team?(vet)).to be(true)
    end

    it "sem o papel → não (Q12)" do
      vet = veterinarian!
      vet.memberships.active.find_by!(role: Zoonoses::Catalog::ROLE).revoke!
      expect(described_class.veterinarian?(vet.reload)).to be(false)
    end

    it "vínculo numa UBS → não" do
      vet = veterinarian!(unit: create_unit("UBS #{SecureRandom.hex(2)}"))
      expect(described_class.veterinarian?(vet)).to be(false)
    end

    it "vínculo encerrado, unidade inativa ou outro CBO → não" do
      ended = veterinarian!
      ProfessionalLink.where(professional_id: ended.professional.id).update_all(ended_at: Time.current, ended_by_user_id: ended.id)
      expect(described_class.veterinarian?(ended)).to be(false)

      inactive = uvz_unit!
      vet = veterinarian!(unit: inactive)
      inactive.update_columns(active: false)
      expect(described_class.veterinarian?(vet)).to be(false)

      # Perfil CRMV completo, papel da equipe, mas o vínculo na UVZ é de outro CBO.
      other_cbo = zoonoses_team!
      Professional.create!(user: other_cbo, professional_name: "Outro CBO", cns: valid_cns(registry_seq!), council: "CRMV",
                           council_state: "PR", registration_number: (80_000 + registry_seq!).to_s)
      link_professional!(other_cbo.reload, uvz_unit!, cbo: "223505")
      expect(described_class.veterinarian?(other_cbo)).to be(false)
    end

    # O CHECK do perfil é tudo ou nada (ck_professionals_council_all_or_none):
    # sem registration_number, o perfil fica sem conselho nenhum.
    it "sem registration_number → não; conselho que não é CRMV → não" do
      vet = veterinarian!
      vet.professional.update!(council: nil, council_state: nil, registration_number: nil)
      expect(described_class.veterinarian?(vet.reload)).to be(false)

      other = veterinarian!
      other.professional.update!(council: "CRM")
      expect(described_class.veterinarian?(other.reload)).to be(false)
    end

    it "sem perfil ou sem usuário → não" do
      expect(described_class.veterinarian?(zoonoses_team!)).to be(false)
      expect(described_class.veterinarian?(nil)).to be(false)
    end
  end

  describe "papéis" do
    it "endemic_coordinator → coordinator? e team?; municipal_admin → só reader?" do
      coordinator = zoonoses_coordinator!
      expect([ described_class.coordinator?(coordinator), described_class.team?(coordinator), described_class.reader?(coordinator) ])
        .to eq([ true, true, true ])

      admin = staff_with("admin-zoo-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")
      expect([ described_class.coordinator?(admin), described_class.team?(admin), described_class.reader?(admin),
               described_class.veterinarian?(admin) ]).to eq([ false, false, true, false ])

      team = zoonoses_team!
      expect([ described_class.coordinator?(team), described_class.team?(team), described_class.reader?(team) ])
        .to eq([ false, true, true ])

      lab = vector_lab!
      expect([ described_class.team?(lab), described_class.reader?(lab) ]).to eq([ false, false ])
      expect([ described_class.team?(nil), described_class.reader?(nil), described_class.coordinator?(nil) ])
        .to eq([ false, false, false ])
    end

    it "team_user_ids: os usuários ativos da equipe e da coordenação, em lote" do
      team = zoonoses_team!
      coordinator = zoonoses_coordinator!
      vet = veterinarian!
      gone = zoonoses_team!.tap(&:deactivate!)
      revoked = zoonoses_team!.tap { |user| user.memberships.active.find_by!(role: Zoonoses::Catalog::ROLE).revoke! }
      staff_with("admin-zoo-#{SecureRandom.hex(3)}@cidade.gov.br", "municipal_admin")

      ids = described_class.team_user_ids
      expect(ids).to match_array([ team.id, coordinator.id, vet.id ])
      expect(ids).not_to include(gone.id, revoked.id)
    end
  end

  describe "campo" do
    let(:household) { registry_household! }
    let(:area) { household.micro_area }

    def field!(cbo)
      field_agent!(cbo: cbo, team: area.team).tap { |agent| assignment!(area, agent.professional) }
    end

    it "ACE e ACS atribuídos → field_agent?; TACS → não; só o ACE → collector?" do
      ace = field!(TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO)
      acs = registry_acs_of(household)
      tacs = field!("322255")
      expect(HomeVisits::Access.registers?(tacs, area.team, micro_area: area, out_of_area: false)).to eq(:ok)

      expect([ ace, acs, tacs ].map { |user| described_class.field_agent?(user, household) }).to eq([ true, true, false ])
      expect([ ace, acs, tacs ].map { |user| described_class.collector?(user, household) }).to eq([ true, false, false ])
    end

    it "ACE fora da microárea do domicílio, domicílio nulo ou usuário da equipe → não" do
      outside = endemic_agent!(team: area.team)
      expect(described_class.field_agent?(outside, household)).to be(false)
      expect(described_class.collector?(outside, household)).to be(false)
      expect(described_class.field_agent?(field!(TerritoryRegistry::Catalog::ENDEMIC_AGENT_CBO), nil)).to be(false)
      expect(described_class.field_agent?(zoonoses_team!, household)).to be(false)
    end
  end
end
