# spec/commands/patients/resolve_concurrency_spec.rb
require "rails_helper"

# ADR 0031 (spec §8): duas consultas do mesmo CPF ao mesmo tempo, por pares
# diferentes (o telefone da família e o da pessoa), criam UM paciente — o lock
# por CPF segura a segunda até a primeira commitar. Threads reais contra
# TEST_CITY_A (sem fixture transacional), como screening_concurrency_spec.
RSpec.describe "Paciente sob disputa" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  before do
    CityConnection.with(TEST_CITY_A) do
      Current.set(city: TEST_CITY_A) do
        tag = SecureRandom.hex(4)
        admin = User.create!(email_address: "adm-#{tag}@c.gov.br", password: "senha-segura-123")
        ids[:admin] = admin.id
        cpf = CampaignHistory.cpf_for("paciente-#{tag}")
        ids[:citizens] = %w[1 2].map do |suffix|
          citizen = Citizen.create!(cpf: cpf, phone: "+55419#{tag.to_i(16).to_s[0, 7].rjust(7, '1')}#{suffix}",
                                    birth_date: "1980-05-10", sex: "female", profile_source: "verified",
                                    full_name: "Maria Aparecida da Silva")
          CitizenVerification.create!(citizen: citizen, verified_by_user: admin, verified_at: Time.current)
          citizen.update!(verification_level: "verified")
          citizen.id
        end
      end
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil
    end
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        patient_ids = Citizen.where(id: ids[:citizens]).pluck(:patient_id).compact.uniq
        DomainEvent.where("payload->>'patient_id' IN (?)", patient_ids.presence || [ "" ]).delete_all
        CitizenVerification.where(citizen_id: ids[:citizens]).delete_all
        Citizen.where(id: ids[:citizens]).delete_all
        PatientProfileDivergence.where(patient_id: patient_ids).delete_all
        Patient.where(id: patient_ids).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin))
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  it "a segunda espera o lock do CPF e liga ao mesmo paciente" do
    holder = nil
    holding = Queue.new
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == "patient.created"
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first = Queue.new
    go = Queue.new
    threads << (holder = Thread.new do
      go.pop(timeout: 5)
      first << in_city { Patients::Resolve.call(Citizen.find(ids[:citizens][0])) }
    end)
    go << true
    holding.pop(timeout: 5) or raise "a primeira não segurou o lock"

    second = Queue.new
    threads << other = Thread.new { second << in_city { Patients::Resolve.call(Citizen.find(ids[:citizens][1])) } }
    expect(wait_for_lock_wait).to be(true)

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    a = first.pop(timeout: 1)
    b = second.pop(timeout: 1)
    expect([ a.payload[:created], b.payload[:created] ]).to eq([ true, false ])
    expect(b.payload[:patient].id).to eq(a.payload[:patient].id)
    in_city { expect(Citizen.where(id: ids[:citizens]).distinct.pluck(:patient_id)).to eq([ a.payload[:patient].id ]) }
  end
end
