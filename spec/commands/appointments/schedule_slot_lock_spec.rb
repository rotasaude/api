require "rails_helper"

# api#26: duas recepções marcando o mesmo horário ao mesmo tempo. A trava
# (pg_advisory_xact_lock por unidade + início) serializa as duas: a segunda
# só conta os horários vivos depois do COMMIT da primeira. Threads reais,
# sem fixture transacional (mesmo padrão de spec/models/health_unit_lock_spec.rb);
# a trava não escreve nada, então não há o que limpar.
RSpec.describe "Appointments::Schedule.lock_slot!" do
  self.use_transactional_tests = false

  let(:unit_id) { SecureRandom.uuid }
  let(:slot) { Time.zone.parse("2026-10-06 14:00") }
  let(:release) { Queue.new }
  let(:threads) { [] }

  after do
    2.times { release << true }
    threads.each { |t| t.join(5) || t.kill }
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { ApplicationRecord.transaction(&) }

  def hold(unit, at)
    locked = Queue.new
    threads << Thread.new do
      in_city do
        Appointments::Schedule.lock_slot!(unit, at)
        locked << true
        release.pop
      end
    end
    locked.pop(timeout: 5) or raise "a thread não pegou a trava"
  end

  it "a mesma unidade e o mesmo início esperam" do
    hold(unit_id, slot)
    threads << waiter = Thread.new { in_city { Appointments::Schedule.lock_slot!(unit_id, slot) } }
    expect(waiter.join(0.5)).to be_nil
    release << true
    expect(waiter.join(5)).to be(waiter)
  end

  it "outro início ou outra unidade não esperam" do
    hold(unit_id, slot)
    threads << other_time = Thread.new { in_city { Appointments::Schedule.lock_slot!(unit_id, slot + 1.minute) } }
    threads << other_unit = Thread.new { in_city { Appointments::Schedule.lock_slot!(SecureRandom.uuid, slot) } }
    expect(other_time.join(5)).to be(other_time)
    expect(other_unit.join(5)).to be(other_unit)
  end
end
