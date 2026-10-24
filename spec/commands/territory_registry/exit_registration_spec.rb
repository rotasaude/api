require "rails_helper"

# Módulo 24a (contrato §5, §14 L9; plano, Desvio 12): a saída confere o
# escopo de novo sob a trava do cadastro. Se o domicílio mudou de microárea
# enquanto a saída esperava (a cascata do SaveHousehold levou o cadastro para
# outra equipe ou outra microárea), a saída devolve stale_version — nunca 500
# nem a saída gravada pelo ACS antigo.
RSpec.describe TerritoryRegistry::ExitRegistration do
  before { registry_city! }

  let(:household) { registry_household! }
  let(:registration) { registry_registration!(household: household) }
  let(:acs) { registry_acs_of(household) }
  let(:exit_params) { { "reason" => "moved", "on" => Time.zone.today.iso8601 } }

  # A cascata comitada entre a checagem de escopo (sem trava) e a trava do cadastro.
  def moved_while_waiting(to:)
    registration
    allow(TerritoryRegistry::Access).to receive(:registrar?).and_wrap_original do |original, *args, **kwargs|
      original.call(*args, **kwargs).tap do
        IndividualRegistration.where(id: registration.id).update_all(micro_area_id: to.id, team_id: to.team_id)
      end
    end
  end

  it "cadastro levado para microárea de outra equipe enquanto esperava → stale_version, nada gravado" do
    other_team = registry_team!(care_unit!)
    moved_while_waiting(to: registry_micro_area!(code: "07", team: other_team))
    result = described_class.call(registration: registration, params: exit_params, by: acs)
    expect(result.reason).to eq(:stale_version)
    expect(registration.reload).to have_attributes(exit_reason: nil, version: 1)
  end

  it "mesma equipe, microárea de outro ACS → stale_version (o ACS antigo não grava a saída)" do
    moved_while_waiting(to: registry_micro_area!(code: "08", team: household.micro_area.team, acs: registry_acs!(care_unit!, team: household.micro_area.team)))
    result = described_class.call(registration: registration, params: exit_params, by: acs)
    expect(result.reason).to eq(:stale_version)
    expect(registration.reload.exit_reason).to be_nil
  end

  it "sem mudança: grava a saída (versão exit) e o evento" do
    result = described_class.call(registration: registration, params: exit_params, by: acs)
    expect(result).to be_ok
    expect(registration.reload).to have_attributes(exit_reason: "moved", version: 2)
    expect(result.payload[:version].origin).to eq("exit")
  end
end
