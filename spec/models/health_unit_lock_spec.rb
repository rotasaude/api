require "rails_helper"

# Módulo 09: a desativação (with_lock, FOR UPDATE) e quem liga trabalho novo
# à unidade (HealthUnit.lock_active!, FOR SHARE) se excluem. Só threads reais
# contra o banco real de TEST_CITY_A (sem fixture transacional) exercitam o
# lock do Postgres — mesmo padrão de spec/commands/city_lifecycle/invite_admin_spec.rb.
RSpec.describe "HealthUnit lock contra a desativação" do
  self.use_transactional_tests = false

  let(:name) { "UBS Trava #{SecureRandom.hex(4)}" }
  let!(:unit_id) { CityConnection.with(TEST_CITY_A) { HealthUnit.create!(name: name, kind: "ubs").id } }
  let(:release) { Queue.new }
  let(:threads) { [] }

  # Os writes aqui commitam de verdade. Mesmo com a expectativa falhando no
  # meio, solta e encerra as threads (senão a que segura o lock prende o
  # processo) e só então apaga a unidade, para não vazar para outras specs.
  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
    CityConnection.with(TEST_CITY_A) { HealthUnit.where(id: unit_id).delete_all }
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { ApplicationRecord.transaction(&) }

  it "a desativação espera o check-in em curso terminar" do
    locked = Queue.new
    threads << holder = Thread.new do
      in_city do
        HealthUnit.lock_active!(unit_id)
        locked << true
        release.pop
      end
    end
    locked.pop(timeout: 5) or raise "a thread não pegou o lock"

    threads << deactivator = Thread.new do
      in_city { HealthUnit.find(unit_id).with_lock { HealthUnit.where(id: unit_id).update_all(active: false) } }
    end
    expect(deactivator.join(0.5)).to be_nil # ainda bloqueada pelo FOR SHARE

    release << true
    holder.join
    expect(deactivator.join(5)).to be(deactivator)
    expect(CityConnection.with(TEST_CITY_A) { HealthUnit.find(unit_id).active }).to be(false)
  end

  it "o check-in que espera a desativação relê a unidade inativa e levanta Inactive" do
    locked = Queue.new
    threads << deactivator = Thread.new do
      in_city do
        HealthUnit.find(unit_id).with_lock do
          HealthUnit.where(id: unit_id).update_all(active: false)
          locked << true
          release.pop
        end
      end
    end
    locked.pop(timeout: 5) or raise "a thread não pegou o lock"

    outcome = Queue.new
    threads << checker = Thread.new do
      in_city { HealthUnit.lock_active!(unit_id) }
      outcome << :locked
    rescue HealthUnit::Inactive
      outcome << :inactive
    end
    expect(checker.join(0.5)).to be_nil # ainda bloqueado pelo FOR UPDATE

    release << true
    deactivator.join
    checker.join(5)
    expect(outcome.pop(timeout: 5)).to eq(:inactive)
  end
end
