require "rails_helper"

# Revisão da Task 9 do 32b (ADR 0050; contrato §6 e §12 Q5): a dose em dobro e
# o max_per_day são por MEDICAMENTO (catalog_item_id), e a mesma versão pode
# trazer o mesmo medicamento em dois itens. O índice
# idx_urgency_administrations_slot é por (item, horário), então só a trava de
# TODOS os itens do medicamento na prescrição serializa as duas checagens.
# A primeira checagem fica parada depois de gravar (antes do commit); a
# segunda, de OUTRO item do mesmo medicamento, espera na trava dos itens;
# solta a primeira, a segunda relê e recusa. Threads reais contra TEST_CITY_A
# (sem fixture transacional), como start_observation_concurrency_spec.rb; a
# prescrição é gravada direto (o catálogo da plataforma não entra) e o after
# solta as threads e apaga tudo o que commitou.
RSpec.describe Urgency::RecordAdministration, "concorrência" do
  self.use_transactional_tests = false

  let(:release) { Queue.new }
  let(:threads) { [] }
  let(:ids) { {} }

  def professional!(tag, suffix, cbo, admin)
    user = User.create!(email_address: "#{suffix}-#{tag}@c.gov.br", password: "senha-segura-123")
    yield user.id
    Membership.create!(user: user, role: "health_professional", granted_at: Time.current)
    professional = Professional.create!(user: user, professional_name: "Profissional #{suffix}", council: "COREN", council_state: "PR",
                                        registration_number: "#{tag.to_i(16).to_s[0, 6]}#{suffix.length}",
                                        cns: Professionals::Cns.generate("adm:#{tag}:#{suffix}"))
    ProfessionalLink.create!(professional: professional, health_unit_id: ids[:unit], cbo_code: cbo, started_at: Time.current,
                             started_by_user: admin)
    user
  end

  before do
    in_city do
      tag = SecureRandom.hex(4)
      reception = User.create!(email_address: "recepcao-adm-#{tag}@c.gov.br", password: "senha-segura-123")
      ids[:admin] = reception.id
      Membership.create!(user: reception, role: "citizen_verifier", granted_at: Time.current)
      ids[:unit] = HealthUnit.create!(name: "UPA Checagem #{tag}", kind: "upa").id
      doctor = professional!(tag, "medico", "225125", reception) { |id| ids[:doctor] = id }
      professional!(tag, "enfermeira", "223505", reception) { |id| ids[:doc_user] = id }
      attrs = { "full_name" => "Carlos Eduardo Pinto", "birth_date" => "1980-01-01", "sex" => "male",
                "no_cpf_reason" => "3", "cns" => Professionals::Cns.generate("adm-paciente:#{tag}") }
      ids[:patient] = Patients::CreateTyped.call(attrs: attrs, by: reception).payload.fetch(:patient).id
      encounter = Urgency::Arrive.call(health_unit_id: ids[:unit], patient_id: ids[:patient], by: reception, waiting_room: false)
                                 .payload.fetch(:encounter)
      ids[:encounter] = encounter.id
      ids[:attendance] = encounter.attendance_id
      link = Urgency::Access.physician_link(doctor, ids[:unit])
      ids[:prescription] = UrgencyPrescription.create!(urgency_encounter: encounter, version: 1, status: "active", prescribed_at: 1.minute.ago,
                                                       prescribed_by_user: doctor, professional_link: link, cbo_code: link.cbo_code).id
    end
  end

  after do
    3.times { release << true }
    threads.each do |t|
      t.join(5) || t.kill
    rescue StandardError
      nil # join relança a exceção da thread; o exemplo já falhou e a limpeza precisa rodar
    end
    CityConnection.with(TEST_CITY_A) do
      ApplicationRecord.transaction do
        ApplicationRecord.connection.execute("SET LOCAL session_replication_role = replica")
        DomainEvent.where("payload->>'patient_id' = ? OR payload->>'encounter_id' = ? OR payload->>'attendance_id' = ?",
                          ids[:patient].to_s, ids[:encounter].to_s, ids[:attendance].to_s).delete_all
        UrgencyAdministration.where(urgency_encounter_id: ids[:encounter]).delete_all
        UrgencyPrescriptionItem.where(urgency_prescription_id: ids[:prescription]).delete_all
        UrgencyPrescription.where(id: ids[:prescription]).delete_all
        UrgencyEncounter.where(id: ids[:encounter]).delete_all
        AttendanceCall.where(attendance_id: ids[:attendance]).delete_all
        Attendance.where(id: ids[:attendance]).delete_all
        Patient.where(id: ids[:patient]).delete_all
      end
    end
    purge_committed_rows(ids.slice(:admin, :unit, :doctor, :doc_user))
  end

  def in_city(&) = CityConnection.with(TEST_CITY_A) { Current.set(city: TEST_CITY_A, &) }

  # Dois itens do MESMO medicamento na mesma versão.
  def items!(**frequency)
    drug = SecureRandom.uuid
    first_dose_at = Time.current.change(sec: 0)
    in_city do
      Array.new(2) do |n|
        UrgencyPrescriptionItem.create!(urgency_prescription_id: ids[:prescription], position: n + 1, catalog_item_id: drug, catmat_code: 268_856,
                                        stock_unit: "comprimido", dose: 50, dose_unit: "mg", route: "oral", first_dose_at: first_dose_at, **frequency)
      end
    end
  end

  def check(item, body)
    in_city do
      described_class.call(attrs: { "prescription_item_id" => item.id }.merge(body), by: User.find(ids[:doc_user]), stock: false)
    end
  end

  # A primeira checagem grava, publica e fica parada antes do commit; a
  # segunda (outro item do mesmo medicamento) tem de esperar na trava.
  def race(first, second, body)
    holding = Queue.new
    holder = nil
    original = DomainEvents.method(:publish)
    allow(DomainEvents).to receive(:publish) do |*args, **kwargs, &blk|
      result = original.call(*args, **kwargs, &blk)
      if Thread.current == holder && args.first == described_class::EVENT
        holding << true
        release.pop(timeout: 10) or raise "timeout esperando release"
      end
      result
    end

    first_result = Queue.new
    threads << (holder = Thread.new { first_result << check(first, body.(first)) })
    holding.pop(timeout: 5) or raise "a primeira checagem não chegou a gravar"

    second_result = Queue.new
    threads << other = Thread.new { second_result << check(second, body.(second)) }
    in_city { expect(wait_for_lock_wait).to be(true) } # a segunda espera na trava dos itens do medicamento

    release << true
    expect(holder.join(5)).to be(holder)
    expect(other.join(5)).to be(other)
    [ first_result.pop(timeout: 1), second_result.pop(timeout: 1) ].map { |r| r.ok? ? :ok : r.reason }
  end

  it "dois itens do mesmo medicamento, o mesmo horário ao mesmo tempo: um vence, o outro 409 slot_taken" do
    first, second = items!(frequency_kind: "interval", interval_hours: 8)
    body = ->(row) { { "scheduled_at" => row.first_dose_at.iso8601, "status" => "administered" } }
    expect(race(first, second, body)).to eq([ :ok, :slot_taken ])
    in_city { expect(UrgencyAdministration.where(urgency_encounter_id: ids[:encounter]).count).to eq(1) }
  end

  it "dois itens se necessário do mesmo medicamento no limite ao mesmo tempo: um vence, o outro 422 max_per_day_reached" do
    first, second = items!(frequency_kind: "if_needed", max_per_day: 1)
    body = ->(_row) { { "status" => "administered" } }
    expect(race(first, second, body)).to eq([ :ok, :max_per_day_reached ])
    in_city { expect(UrgencyAdministration.where(urgency_encounter_id: ids[:encounter]).count).to eq(1) }
  end
end
