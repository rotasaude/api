require "rails_helper"

# Review Focus 5 (plano, Desvio 12): dois profissionais cadastram o mesmo
# paciente ao mesmo tempo — um grava, o outro already_registered; nunca dois
# ativos nem 500 (trava do paciente + índice único parcial). E o domicílio
# gravado enquanto um cadastro entra nele não trava em deadlock (paciente →
# domicílio → família → cadastro). Threads reais contra TEST_CITY_A, sem
# fixture transacional (o padrão de resolve_concurrency_spec): a primeira
# segura a transação depois de gravar, a segunda prova que espera a trava, e
# a limpeza apaga tudo o que nasceu no exemplo. A plataforma não é tocada (sem
# exportação LEDI utilizável, a ficha não nasce — não é o que se prova aqui).
RSpec.describe "Cadastro individual — concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:go) { Queue.new }

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # id de cada linha de cada tabela com id, antes do exemplo.
  def snapshot
    connection = ApplicationRecord.connection
    connection.tables.select { |table| connection.column_exists?(table, :id) }
              .to_h { |table| [ table, connection.select_values("SELECT id::text FROM #{connection.quote_table_name(table)}").to_set ] }
  end

  before do
    @before = in_city { snapshot }
    @ids = in_city do
      unit = care_unit!
      team = registry_team!(unit)
      acs = registry_acs!(unit, team: team)
      area = registry_micro_area!(code: "01", team: team, acs: acs)
      household = registry_household!(micro_area: area)
      { household: household.id, acs: acs.id, patient: registry_patient!.id }
    end
  end

  after do
    3.times { release << true }
    threads.each do |thread|
      thread.join(5) || thread.kill
    rescue StandardError
      nil
    end
    in_city do
      ApplicationRecord.transaction do
        connection = ApplicationRecord.connection
        connection.execute("SET LOCAL session_replication_role = replica")
        snapshot.each do |table, ids|
          fresh = ids - @before.fetch(table, Set.new)
          next if fresh.empty?

          connection.execute("DELETE FROM #{connection.quote_table_name(table)} WHERE id::text IN (#{fresh.map { connection.quote(_1) }.join(',')})")
        end
      end
    end
  end

  def household = Household.find(@ids[:household])
  def acs = User.find(@ids[:acs])
  def registration_params = registry_registration_params(household, patient: Patient.find(@ids[:patient]))

  # Segura a thread `holder` logo depois do evento `name` (ainda na transação).
  def hold_after(name)
    holding = Queue.new
    holder = [ nil ]
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder[0] && args.first == name
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end
    [ holder, holding ]
  end

  def outcome(result) = result.ok? ? :ok : result.reason

  it "dois cadastros do mesmo paciente ao mesmo tempo: um grava, o outro already_registered; nunca dois ativos" do
    holder, holding = hold_after("territory_registration.saved")
    first = Queue.new
    params = in_city { registration_params }
    threads << (holder[0] = Thread.new { go.pop(timeout: 5) && first << in_city { TerritoryRegistry::SaveRegistration.call(params: params, by: acs) } })
    go << true
    holding.pop(timeout: 5) or raise "o primeiro não segurou a transação"

    second = Queue.new
    threads << Thread.new { second << in_city { TerritoryRegistry::SaveRegistration.call(params: params, by: acs) } }
    expect(wait_for_lock_wait).to be(true)
    release << true

    a = first.pop(timeout: 10)
    b = second.pop(timeout: 10)
    expect([ outcome(a), outcome(b) ]).to eq([ :ok, :already_registered ])
    expect(b.details).to eq(registration_id: a.payload[:registration].id)
    in_city { expect(IndividualRegistration.active_registrations.where(patient_id: @ids[:patient]).count).to eq(1) }
  end

  it "gravar o domicílio enquanto um cadastro entra nele: sem deadlock; o domicílio recomeça e leva o morador novo" do
    holder, holding = hold_after("territory_registration.saved")
    saved = Queue.new
    params = in_city { registration_params }
    threads << (holder[0] = Thread.new { go.pop(timeout: 5) && saved << in_city { TerritoryRegistry::SaveRegistration.call(params: params, by: acs) } })
    go << true
    holding.pop(timeout: 5) or raise "o cadastro não segurou a transação"

    rewritten = Queue.new
    household_params = in_city { registry_household_params(household).deep_merge("address" => { "street" => "Nova" }, "version" => 1) }
    threads << Thread.new do
      rewritten << in_city { TerritoryRegistry::SaveHousehold.call(params: household_params, by: acs, household: household) }
    end
    expect(wait_for_lock_wait).to be(true)
    release << true

    expect(outcome(saved.pop(timeout: 10))).to eq(:ok)
    expect(outcome(rewritten.pop(timeout: 10))).to eq(:ok)
    in_city { expect(Patient.find(@ids[:patient]).address_street).to eq("Nova") }
  end

  it "o domicílio grava primeiro: o cadastro espera a trava do domicílio e entra depois, com o endereço novo" do
    holder, holding = hold_after("household.saved")
    rewritten = Queue.new
    household_params = in_city { registry_household_params(household).deep_merge("address" => { "street" => "Nova" }, "version" => 1) }
    threads << (holder[0] = Thread.new do
      go.pop(timeout: 5) && rewritten << in_city { TerritoryRegistry::SaveHousehold.call(params: household_params, by: acs, household: household) }
    end)
    go << true
    holding.pop(timeout: 5) or raise "o domicílio não segurou a transação"

    saved = Queue.new
    params = in_city { registration_params }
    threads << Thread.new { saved << in_city { TerritoryRegistry::SaveRegistration.call(params: params, by: acs) } }
    expect(wait_for_lock_wait).to be(true)
    release << true

    expect(outcome(rewritten.pop(timeout: 10))).to eq(:ok)
    expect(outcome(saved.pop(timeout: 10))).to eq(:ok)
    in_city { expect(Patient.find(@ids[:patient]).address_street).to eq("Nova") }
  end
end
