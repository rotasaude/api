require "rails_helper"

# F-11.2: Territory::ReplaceCoverage trava o bairro (FOR UPDATE) antes de ler a
# cobertura atual. Duas substituições simultâneas no mesmo bairro se
# serializam: a segunda espera a primeira commitar e calcula
# adicionados/removidos sobre o estado JÁ novo — sem update perdido, sem linha
# duplicada, e eventos coverage_changed coerentes entre si. Threads reais, sem
# fixture transacional — mesmo padrão de spec/models/health_unit_lock_spec.rb.
RSpec.describe "Territory::ReplaceCoverage sob concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    CityConnection.with(TEST_CITY_A) do
      tag = SecureRandom.hex(4)
      ids[:neighborhood] = Neighborhood.create!(name: "Bairro Trava #{tag}", source: "manual").id
      ids[:u1] = HealthUnit.create!(name: "UBS Trava Um #{tag}", kind: "ubs").id
      ids[:u2] = HealthUnit.create!(name: "UBS Trava Dois #{tag}", kind: "ubs").id
    end
  end

  # Os writes commitam de verdade. Solta e encerra as threads antes de limpar
  # (a que segura o lock prenderia o processo). domain_events recusa DELETE por
  # trigger: a limpeza desliga os triggers só na própria transação, como em
  # spec/support/committed_rows_cleanup.rb.
  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where("payload->>'neighborhood_id' = ?", ids[:neighborhood]).delete_all
        NeighborhoodCoverage.where(neighborhood_id: ids[:neighborhood]).delete_all
        Neighborhood.where(id: ids[:neighborhood]).delete_all
        HealthUnit.where(id: ids.values_at(:u1, :u2)).delete_all
      end
    end
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { ApplicationRecord.transaction(&) }

  def replace(unit_keys)
    Territory::ReplaceCoverage.call(neighborhood: Neighborhood.find(ids[:neighborhood]),
                                    health_unit_ids: ids.values_at(*unit_keys), by: nil)
  end

  def city_read(&) = CityConnection.with(TEST_CITY_A, &)

  def coverage = city_read { NeighborhoodCoverage.where(neighborhood_id: ids[:neighborhood]).pluck(:health_unit_id) }

  def events
    city_read do
      DomainEvent.where(name: "neighborhood.coverage_changed")
                 .where("payload->>'neighborhood_id' = ?", ids[:neighborhood]).order(:occurred_at).map(&:payload)
    end
  end

  # A primeira chamada roda dentro de uma transação externa que só commita
  # quando o exemplo manda: o FOR UPDATE do bairro fica preso até lá.
  def hold_first_call(unit_keys)
    locked = Queue.new
    first = Queue.new
    threads << holder = Thread.new do
      in_city do
        first << replace(unit_keys)
        locked << true
        release.pop
      end
    end
    locked.pop(timeout: 5) or raise "a primeira chamada não pegou o lock"
    [ holder, first.pop(timeout: 5) ]
  end

  def start_second_call(unit_keys)
    outcome = Queue.new
    threads << Thread.new do
      city_read { outcome << replace(unit_keys) }
    rescue StandardError => e
      outcome << e
    end
    outcome
  end

  it "a segunda substituição espera a primeira e calcula a diferença sobre o estado já commitado" do
    holder, first = hold_first_call(%i[u1])
    outcome = start_second_call(%i[u2])

    expect(wait_for_lock_wait).to be(true) # a segunda está parada no FOR UPDATE do bairro
    expect(outcome.pop(timeout: 0.3)).to be_nil # e não terminou enquanto a primeira não commitou

    release << true
    expect(holder.join(5)).to be(holder)
    second = outcome.pop(timeout: 5)

    expect(first.payload).to include(added: [ ids[:u1] ], removed: [])
    expect(second).to be_ok
    expect(second.payload).to include(added: [ ids[:u2] ], removed: [ ids[:u1] ])
    expect(coverage).to eq([ ids[:u2] ]) # vale a última, sem o u1 perdido no meio
    expect(events.map { _1.slice("added_unit_ids", "removed_unit_ids") }).to eq(
      [
        { "added_unit_ids" => [ ids[:u1] ], "removed_unit_ids" => [] },
        { "added_unit_ids" => [ ids[:u2] ], "removed_unit_ids" => [ ids[:u1] ] }
      ]
    )
  end

  it "a segunda que repete uma unidade já adicionada pela primeira não duplica nem estoura o índice único" do
    holder, first = hold_first_call(%i[u1 u2])
    outcome = start_second_call(%i[u1])

    expect(wait_for_lock_wait).to be(true)

    release << true
    expect(holder.join(5)).to be(holder)
    second = outcome.pop(timeout: 5)

    expect(first.payload[:added]).to match_array(ids.values_at(:u1, :u2))
    expect(second).to be_ok # sem RecordNotUnique
    expect(second.payload).to include(added: [], removed: [ ids[:u2] ])
    expect(coverage).to eq([ ids[:u1] ])
    expect(events.map { _1["removed_unit_ids"] }).to eq([ [], [ ids[:u2] ] ])
  end
end
