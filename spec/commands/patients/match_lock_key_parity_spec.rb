require "rails_helper"

# Herdado da revisão da Task 10 do módulo 27a: o cadastro territorial (24a), a
# notificação manual (25) e a receita externa (27a) digitam paciente novo sob o
# MESMO lock consultivo da match_key (pg_advisory_xact_lock): é o que serializa
# dois cadastros da mesma pessoa vindos de módulos diferentes. As três cópias
# de `match_lock_key` têm de dar a mesma chave para a mesma match_key; se uma
# divergir, os dois módulos deixam de se enxergar e o duplicado passa.
RSpec.describe "match_lock_key do paciente digitado (24a, 25, 27a)" do
  let(:modules) { [ TerritoryRegistry::SaveRegistration, Surveillance::CreateManual, Pharmacy::RecordExternalPrescription ] }

  it "as três dão a mesma chave para a mesma match_key, e chaves diferentes para match_keys diferentes" do
    keys = [ Patients::MatchKey.for("Carlos Eduardo Pereira", "1985-03-12"), Patients::MatchKey.for("Maria Aparecida da Silva", "1979-11-02") ]
    expect(keys.uniq.size).to eq(2)
    keys.each do |key|
      locks = modules.map { |mod| mod.send(:match_lock_key, key) }
      expect(locks.uniq.size).to eq(1), "match_lock_key diverge entre #{modules.map(&:name).join(', ')}: #{locks.inspect}"
      expect(locks.first).to be_a(Integer).and be_between(0, 2**63 - 1)
    end
    expect(modules.first.send(:match_lock_key, keys.first)).not_to eq(modules.first.send(:match_lock_key, keys.last))
  end
end
