# spec/commands/cnes/apply_lock_spec.rb
require "rails_helper"

# Review Focus 4: dois administradores confirmam a mesma proposta ao mesmo
# tempo. O segundo espera a trava (pg_advisory_xact_lock), recalcula sobre o
# estado já commitado e recebe stale — sem escrita dupla. Threads reais, sem
# fixture transacional (padrão de spec/commands/territory/replace_coverage_lock_spec.rb).
RSpec.describe "Cnes::Apply sob concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }
  let(:by) { Data.define(:id).new(id: SecureRandom.uuid) }

  before do
    CityConnection.with(TEST_CITY_A) do
      tag = SecureRandom.hex(4)
      ids[:unit] = HealthUnit.create!(name: "UBS Trava CNES #{tag}", kind: "ubs").id
      ids[:name] = "UBS TRAVA CNES #{tag.upcase}"
      ids[:profile_created] = CityProfile.current.nil?
      profile = CityProfile.current || CityProfile.new(name: "Cidade", uf: "PR")
      ids[:previous_ibge] = profile.ibge_code
      profile.update!(ibge_code: "4106902")
    end
    ids[:snapshot] = Cnes::SnapshotWriter.write!(competence: "209912", ibge_code: "4106902",
                                                 establishments: [ { cnes: "7777777", name: ids[:name], unit_type: "02" } ],
                                                 teams: [], bonds: []).id
  end

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    CnesSnapshot.where(id: ids[:snapshot]).delete_all
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where(name: "cnes.proposals_applied").where("payload->>'user_id' = ?", by.id).delete_all
        HealthUnit.where(id: ids[:unit]).delete_all
        ids[:profile_created] ? CityProfile.delete_all : CityProfile.update_all(ibge_code: ids[:previous_ibge])
      end
    end
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { ApplicationRecord.transaction(&) }

  it "o segundo espera e recebe stale" do
    id = Cnes::Proposal.for(TEST_CITY_A)[:proposals].find { |p| p[:target][:health_unit_id] == ids[:unit] }[:id]
    first = Queue.new
    locked = Queue.new
    threads << Thread.new do
      in_city do
        first << Cnes::Apply.call(city: TEST_CITY_A, proposal_ids: [ id ], by: by)
        locked << true
        release.pop
      end
    end
    locked.pop(timeout: 5) or raise "a primeira chamada não pegou a trava"

    second = Queue.new
    threads << Thread.new do
      CityConnection.with(TEST_CITY_A) { second << Cnes::Apply.call(city: TEST_CITY_A, proposal_ids: [ id ], by: by) }
    rescue StandardError => e
      second << e
    end
    expect(second.pop(timeout: 0.5)).to be_nil

    release << true
    threads.first.join(5)
    outcome = second.pop(timeout: 5)
    expect(first.pop.payload).to eq(applied: 1, skipped: [])
    expect(outcome.payload).to eq(applied: 0, skipped: [ { id: id, reason: "stale" } ])
    expect(CityConnection.with(TEST_CITY_A) { HealthUnit.find(ids[:unit]).cnes }).to eq("7777777")
  end
end
