require "rails_helper"

# Herdado da revisão da Task 10 do módulo 27a: o cadastro territorial (24a), a
# notificação manual (25) e a receita externa (27a) digitam paciente novo sob o
# MESMO lock consultivo da match_key (pg_advisory_xact_lock): é o que serializa
# dois cadastros da mesma pessoa vindos de módulos diferentes. As três cópias
# de `match_lock_key` têm de dar a mesma chave para a mesma match_key; se uma
# divergir, os dois módulos deixam de se enxergar e o duplicado passa.
#
# Módulo 29: a receita externa (27a) e a caderneta (29) deixaram de ter cópia
# própria: ambas criam o paciente por Patients::CreateReviewed, cuja `lock_key`
# é a chave delas. Os dois módulos usam essa mesma chave, então comparar com
# ela cobre a farmácia e a sala de vacina.
RSpec.describe "chave de trava do paciente digitado (24a, 25, 27a, 29)" do
  let(:modules) do
    { TerritoryRegistry::SaveRegistration => :match_lock_key, Surveillance::CreateManual => :match_lock_key,
      Patients::CreateReviewed => :lock_key }
  end

  it "as três dão a mesma chave para a mesma match_key, e chaves diferentes para match_keys diferentes" do
    keys = [ Patients::MatchKey.for("Carlos Eduardo Pereira", "1985-03-12"), Patients::MatchKey.for("Maria Aparecida da Silva", "1979-11-02") ]
    expect(keys.uniq.size).to eq(2)
    keys.each do |key|
      locks = modules.map { |mod, meth| mod.send(meth, key) }
      expect(locks.uniq.size).to eq(1), "match_lock_key diverge entre #{modules.keys.map(&:name).join(', ')}: #{locks.inspect}"
      expect(locks.first).to be_a(Integer).and be_between(0, 2**63 - 1)
    end
    expect(Patients::CreateReviewed.send(:lock_key, keys.first)).not_to eq(Patients::CreateReviewed.send(:lock_key, keys.last))
  end
end
