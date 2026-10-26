require "rails_helper"

# Contrato §14 L29: responsible_exited — família ATIVA cujo responsável teve
# óbito (em qualquer cadastro) ou saiu deste domicílio por mudança sem outro
# cadastro ativo aqui. Família em mudança nunca conta.
RSpec.describe TerritoryRegistry::Families do
  before { registry_city! }

  let(:household) { registry_household! }
  let(:acs) { registry_acs_of(household) }

  def leave!(registration, reason)
    params = { "reason" => reason, "on" => Time.zone.today.iso8601 }
    params["death_on"] = Time.zone.today.iso8601 if reason == "death"
    expect(TerritoryRegistry::ExitRegistration.call(registration: registration.reload, params: params, by: acs)).to be_ok
  end

  def exited?(family) = described_class.responsible_exited_ids([ family.reload ]).include?(family.id)

  it "mudança: true quando saiu daqui; false quando voltou a se cadastrar aqui" do
    responsible = registry_patient!
    registration = registry_registration!(patient: responsible, household: household)
    family = registry_family!(household, responsible: responsible)
    expect(exited?(family)).to be(false)
    leave!(registration, "moved")
    expect(exited?(family)).to be(true)
    registry_registration!(patient: responsible, household: household)
    expect(exited?(family)).to be(false)
  end

  it "mudança: cadastrado depois em outro domicílio segue true aqui" do
    responsible = registry_patient!
    registration = registry_registration!(patient: responsible, household: household)
    family = registry_family!(household, responsible: responsible)
    leave!(registration, "moved")
    registry_registration!(patient: responsible, household: registry_household!(micro_area: household.micro_area))
    expect(exited?(family)).to be(true)
  end

  it "óbito em cadastro de outro domicílio: true; família em mudança: false; responsável sem cadastro: false" do
    responsible = registry_patient!
    elsewhere = registry_registration!(patient: responsible, household: registry_household!(micro_area: household.micro_area))
    family = registry_family!(household, responsible: responsible)
    never = registry_family!(household, responsible: registry_patient!)
    leave!(elsewhere, "death")
    expect(described_class.responsible_exited_ids([ family.reload, never.reload ])).to eq(Set[family.id])
    family.update_columns(moved_out: true)
    expect(exited?(family)).to be(false)
  end
end
