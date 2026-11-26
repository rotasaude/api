require "rails_helper"

# Módulo 26c, Task 10 (contrato §2; Q7, Q8; pré-voo B3, I9; Review Focus 2 e
# 5): o recálculo do estado desejado de um pedido (situação, impressão digital
# e passos) e a situação da linha de envio. O envio não existe ainda (Task 12):
# o aceite é simulado gravando a remessa e o que foi enviado na linha. Os
# pedidos nascem e andam pelos comandos reais da 26a.
RSpec.describe Regulation::RndsSync, type: :model do
  include ActiveSupport::Testing::TimeHelpers

  let(:now) { Time.zone.local(2026, 11, 20, 9, 0) }
  let(:regulator) { regulation_regulator! }
  let(:offer) { offer!(provider: external_provider!) }
  let(:queued_events) { DomainEvent.where(name: "regulation_rnds.queued") }

  before do
    travel_to now
    rnds_regulation_city!(mock: false)
    tick_regulation_events!
  end

  def settings = RegulationRndsSetting.current

  # O que o consumidor faz: cria só com o interruptor ligado.
  def recompute(request, create: Regulation::RndsGate.enabled?(Current.city), **opts)
    described_class.recompute!(request.reload, create: create, now: Time.current, **opts)
  end

  # Pedido com a unidade solicitante com CNES (o documento passa no esqueleto).
  def municipal_request!(**over) = regulation_request!(unit: create_unit("UBS #{SecureRandom.hex(3)}", cnes: regulation_cnes), **over)

  # O aceite da Task 12, simulado: a remessa aceita e o enviado na linha (o
  # desejado, ou o primeiro passo com `step:`).
  def accept!(sync, step: false, rnds_id: "RA#{SecureRandom.hex(8)}")
    sync.reload
    request = sync.regulation_request
    status = step ? sync.pending_steps.first : described_class.target(request, settings: settings)
    code = step ? status.fetch("status") : status.status
    digest = step ? Regulation::RiraBundle.digest(Regulation::RiraBundle.for(request: request, sync: sync, status: status, now: Time.current)) : sync.desired_digest
    RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: sync.last_rnds_id ? "replace" : "create", mira_status: code,
                                   digest: digest, sent_at: Time.current, accepted_at: Time.current, rnds_id: rnds_id, http_status: 201)
    sync.update!(last_rnds_id: rnds_id, last_accepted_at: Time.current, sent_status: code, sent_digest: digest,
                 pending_steps: step ? sync.pending_steps.drop(1) : [], status: code == "excluded" ? "excluded" : "idle",
                 attempts: 0, next_attempt_at: nil)
    travel 1.second
    sync.reload
  end

  def schedule!(request, at: Time.current + 3.days)
    result = CareRegulation::ScheduleExternal.call(request: request.reload, at: at.iso8601, place: "Hospital Regional", notes: nil,
                                                   version: request.version, by: regulator, care_provider_id: offer.care_provider_id)
    raise "agendamento recusado: #{result.reason}" if result.failure?

    request.reload
  end

  def miss!(request)
    ApplicationRecord.transaction do
      request.lock!(CareRegulation::Decide::LOCK)
      CareRegulation::Misses.apply!(request: request, by: regulator)
    end
    request.reload
  end

  def decide!(request, decision)
    result = CareRegulation::Decide.call(request: request.reload, decision: decision, reason: "Motivo da decisão de teste",
                                         version: request.version, by: regulator)
    raise "decisão recusada: #{result.reason}" if result.failure?

    request.reload
  end

  # O paciente perde CPF e CNS "por outro caminho" (Q3, Q8): a identidade do
  # paciente nunca muda no banco (trigger) e o Citizens::Erase retém quem tem
  # pedido de regulação, então o caso de borda entra pelos fatos lidos.
  def strip_identity!
    allow(Regulation::RiraFacts).to receive(:for).and_wrap_original do |original, **kwargs|
      original.call(**kwargs).with(patient_cpf: nil, patient_cns: nil)
    end
  end

  describe ".recompute!" do
    it "pedido promovido com o interruptor ligado → linha queued com pending" do
      request = municipal_request!
      sync = recompute(request)

      expect(sync).to be_persisted
      expect(sync).to have_attributes(status: "queued", desired_status: "pending", pending_steps: [], attempts: 0,
                                      initial_load: false, enqueued_at: Time.current, next_attempt_at: Time.current)
      document = Regulation::RiraBundle.build(facts: Regulation::RiraFacts.for(request: request, settings: settings, credential: nil),
                                              sync: sync, status: Regulation::RndsStatus.for(request, settings: settings), now: Time.current)
      expect(sync.desired_digest).to eq(Regulation::RiraBundle.digest(document))
      expect(queued_events.sole.payload).to eq("regulation_rnds_sync_id" => sync.id, "regulation_request_id" => request.id)
    end

    it "sem credencial (pré-voo I9): a linha nasce e é calculada" do
      IntegrationCredential.where(kind: "rnds_regulation").delete_all
      sync = recompute(municipal_request!, create: true)
      expect(sync).to have_attributes(status: "queued", desired_status: "pending")
      expect(sync.desired_digest).to match(/\A\h{64}\z/)
    end

    it "rascunho e pedido sem linha com create: false → nil, nenhuma linha" do
      expect(recompute(regulation_request!(status: "draft"), create: true)).to be_nil
      expect(recompute(municipal_request!, create: false)).to be_nil
      expect(RegulationRndsSync.count).to eq(0)
    end

    it "desligado → sem linha; linha antiga segue recalculada" do
      old = municipal_request!
      recompute(old)
      Platform::Features.set!(city: Current.city, key: Regulation::RndsGate::KEY, enabled: false, maintainer: ledi_maintainer!)
      fresh = municipal_request!
      decide!(old, "return")
      [ old, fresh ].each do |request|
        event = DomainEvent.where(name: "regulation_request.#{request == old ? 'returned' : 'created'}")
                           .where("payload->>'regulation_request_id' = ?", request.id).order(:occurred_at).last!
        Regulation::RndsSyncJob.new.perform(event_id: event.id, event_name: event.name, city_slug: Current.city.slug, payload: event.payload)
      end

      expect(RegulationRndsSync.find_by(regulation_request_id: fresh.id)).to be_nil
      expect(RegulationRndsSync.find_by!(regulation_request_id: old.id)).to have_attributes(desired_status: "returned-to-requester",
                                                                                             status: "queued")
    end

    it "remarcação de pedido aceito (mesma situação) → queued por digest (retificação)" do
      request = schedule!(reauthorize!(municipal_request!, offer: offer))
      sync = accept!(recompute(request))
      expect(sync).to have_attributes(status: "idle", sent_status: "booked")

      schedule!(request, at: Time.current + 5.days)
      sync = recompute(request)
      expect(sync).to have_attributes(status: "queued", desired_status: "booked", sent_status: "booked", enqueued_at: Time.current)
      expect(sync.desired_digest).not_to eq(sync.sent_digest)
    end

    it "trocar a cor de vermelho para azul num aceito → queued" do
      request = municipal_request!(suggested_color: "red")
      sync = accept!(recompute(request))
      facts = -> { Regulation::RiraFacts.for(request: request.reload, settings: settings, credential: nil) }
      expect(facts.call.priority).to eq("urgent")

      result = CareRegulation::Authorize.call(request: request.reload, offer_id: offer.id, version: request.version, by: regulator,
                                              color: "blue", color_reason: "Reavaliado pelo regulador da central")
      raise "autorização recusada: #{result.reason}" if result.failure?

      sync = recompute(request)
      expect(facts.call.priority).to eq("routine")
      expect(sync).to have_attributes(status: "queued", desired_status: "pending", sent_status: "pending")
      expect(sync.desired_digest).not_to eq(sync.sent_digest)
    end

    it "nada mudou → idle e enqueued_at intacto" do
      request = municipal_request!
      sync = accept!(recompute(request))
      enqueued = sync.enqueued_at
      travel 1.hour

      expect { sync = recompute(request) }.not_to change { queued_events.count }
      expect(sync).to have_attributes(status: "idle", enqueued_at: enqueued)
    end

    # Review Focus 5 (decisão 13, Q7).
    describe "external com send_external desligado" do
      it "aceito antes → desejado excluded; o excluded aceito para; religado → volta a pending substituindo" do
        rnds_settings!(send_external: true)
        request = municipal_request!(status: "external")
        sync = accept!(recompute(request))
        first_id = sync.last_rnds_id

        rnds_settings!(send_external: false)
        sync = recompute(request)
        expect(sync).to have_attributes(status: "queued", desired_status: "excluded", pending_steps: [])
        target = described_class.target(request.reload, settings: settings)
        expect(target).to have_attributes(status: "excluded")
        expect(target.at).to be_present
        document = Regulation::RiraBundle.for(request: request, sync: sync, status: target, now: Time.current)
        expect(Regulation::RiraSkeleton.problems(document)).to eq([])
        composition = document["entry"].first["resource"]
        expect(composition["relatesTo"].sole["targetReference"]).to eq("reference" => "Composition/#{first_id}")
        expect(Regulation::RiraBundle.digest(document)).to eq(sync.desired_digest)

        sync = accept!(sync)
        expect(sync).to have_attributes(status: "excluded", sent_status: "excluded")
        excluded_id = sync.last_rnds_id
        decide!(request, "cancel")
        expect { sync = recompute(request) }.not_to change { queued_events.count }
        expect(sync).to have_attributes(status: "excluded")

        rnds_settings!(send_external: true)
        sync = recompute(request)
        expect(sync).to have_attributes(status: "queued", desired_status: "cancelled", last_rnds_id: excluded_id)
        replacement = Regulation::RiraBundle.for(request: request.reload, sync: sync, status: described_class.target(request, settings: settings),
                                                 now: Time.current)
        expect(replacement["entry"].first["resource"]["relatesTo"].sole["targetReference"])
          .to eq("reference" => "Composition/#{excluded_id}")
      end

      it "nunca aceito → excluded sem remessa e sem chamar a RNDS; religado → queued com pending" do
        fake = fake_rnds!
        rnds_settings!(send_external: true)
        request = municipal_request!(status: "external")
        expect(recompute(request)).to have_attributes(status: "queued", desired_status: "pending")

        rnds_settings!(send_external: false)
        sync = recompute(request)
        expect(sync).to have_attributes(status: "excluded", desired_status: "excluded", last_rnds_id: nil, pending_steps: [])
        expect(sync.deliveries).to be_empty
        expect(fake.log).to be_empty
        expect(WebMock).not_to have_requested(:any, /fake-rnds/)

        rnds_settings!(send_external: true)
        expect(recompute(request)).to have_attributes(status: "queued", desired_status: "pending")
      end

      it "regulado pelo estado sem linha, desligado → não cria" do
        expect(recompute(municipal_request!(status: "external"), create: true)).to be_nil
        expect(RegulationRndsSync.count).to eq(0)
      end

      it "municipal aceito que vira external (MarkExternal) → desejado excluded, queued" do
        request = municipal_request!
        accept!(recompute(request))
        result = CareRegulation::MarkExternal.call(request: request.reload, system: "sisreg", number: "123456789", version: request.version,
                                                   by: regulator)
        raise "recusado: #{result.reason}" if result.failure?

        expect(recompute(request)).to have_attributes(status: "queued", desired_status: "excluded")
      end

      it "nunca aceito mas com remessa sem resposta (timeout) → queued, para a reconciliação" do
        rnds_settings!(send_external: true)
        request = municipal_request!(status: "external")
        sync = recompute(request)
        RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: "pending", digest: sync.desired_digest,
                                       sent_at: Time.current)
        rnds_settings!(send_external: false)
        expect(recompute(request)).to have_attributes(status: "queued", desired_status: "excluded", last_rnds_id: nil)
      end
    end

    # Q8.
    describe "paciente sem CPF nem CNS" do
      it "num pedido já aceito → erased" do
        request = municipal_request!
        accept!(recompute(request))
        strip_identity!
        expect(recompute(request)).to have_attributes(status: "erased")
      end

      it "nunca aceito → fica para a conferência (blocked)" do
        request = municipal_request!
        strip_identity!
        sync = recompute(request)
        expect(sync).to have_attributes(status: "queued", desired_status: "pending")
        facts = Regulation::RiraFacts.for(request: request.reload, settings: settings, credential: nil)
        expect(Regulation::RndsValidation.call(facts: facts, status: described_class.target(request, settings: settings)))
          .to eq([ :blocked, [ "patient_without_cpf_or_cns" ] ])
      end
    end

    # Fix round 1 da revisão da Task 10.
    describe "revisão (I1, I2, I3)" do
      def refuse!(sync, digest: sync.reload.desired_digest, status: "rejected")
        RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: sync.last_rnds_id ? "replace" : "create",
                                       mira_status: sync.desired_status, digest: digest, sent_at: Time.current, http_status: 422,
                                       error_codes: [ "EHR-ERR999" ])
        sync.update_columns(status: status, last_error_codes: [ "EHR-ERR999" ])
        travel 1.second
        sync.reload
      end

      it "I1: gravar os ajustes sem relação com o pedido não mexe no digest nem na situação das linhas excluded" do
        rnds_settings!(send_external: true)
        refused = municipal_request!(status: "external")
        accept!(recompute(refused))
        closed = municipal_request!(status: "external")
        recompute(closed)
        rnds_settings!(send_external: false)
        refused_row = refuse!(recompute(refused))
        closed_row = recompute(closed)
        expect([ refused_row.desired_status, closed_row.status ]).to eq(%w[excluded excluded])
        before = [ refused_row, closed_row ].map { |row| row.reload.slice(:status, :desired_digest, :enqueued_at) }

        travel 1.hour
        rnds_settings!(priority_by_color: { "red" => "urgent", "yellow" => "routine", "green" => "routine", "blue" => "urgent" },
                       specialty_sigtap: { "225125" => "0301010072" })
        expect { [ refused, closed ].each { |request| recompute(request) } }.not_to change { queued_events.count }
        expect([ refused_row, closed_row ].map { |row| row.reload.slice(:status, :desired_digest, :enqueued_at) }).to eq(before)
        expect(refused_row.status).to eq("rejected")
      end

      it "I2: remessa sem resposta depois do último aceite → queued mesmo com o desejado igual ao enviado" do
        request = municipal_request!
        sync = accept!(recompute(request))
        RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "replace", mira_status: sync.desired_status,
                                       digest: sync.desired_digest, sent_at: Time.current)
        sync.update_columns(status: "queued", attempts: 0)
        travel 1.second

        expect(recompute(request)).to have_attributes(status: "queued", desired_digest: sync.sent_digest)
        expect(described_class.unanswered_delivery?(sync.reload)).to be(true)
      end

      it "I2: remessa sem resposta anterior ao último aceite não conta" do
        request = municipal_request!
        sync = recompute(request)
        RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: sync.desired_status,
                                       digest: sync.desired_digest, sent_at: Time.current)
        travel 1.second
        sync = accept!(sync)

        expect(described_class.unanswered_delivery?(sync)).to be(false)
        expect(recompute(request)).to have_attributes(status: "idle")
      end

      it "I3: mudança gravada durante sending e depois 422 do enviado → queued com o conteúdo novo" do
        request = municipal_request!
        sync = recompute(request)
        sent_digest = sync.desired_digest
        sync.update_columns(status: "sending", claimed_at: Time.current)
        decide!(request, "return")
        expect(recompute(request)).to have_attributes(status: "sending", desired_status: "returned-to-requester")

        refuse!(sync, digest: sent_digest)
        sync = recompute(request)
        expect(sync).to have_attributes(status: "queued", desired_status: "returned-to-requester")
        expect(sync.desired_digest).not_to eq(sent_digest)
      end

      it "I3: rejected sem conteúdo novo desde a recusa → segue rejected" do
        request = municipal_request!
        refuse!(recompute(request))
        travel 1.minute
        expect(recompute(request)).to have_attributes(status: "rejected")
      end
    end

    it "linha sending não perde o status (só o desejado muda)" do
      request = municipal_request!
      sync = recompute(request)
      sync.update_columns(status: "sending", claimed_at: Time.current)
      decide!(request, "return")

      sync = recompute(request)
      expect(sync).to have_attributes(status: "sending", desired_status: "returned-to-requester")
      expect(queued_events.count).to eq(1)
    end

    # Pré-voo B3: a tabela de situações (rejected/failed/blocked só voltam com
    # outro conteúdo).
    describe "situação atual × mudança" do
      def row_in(status)
        request = municipal_request!
        sync = recompute(request)
        sync = accept!(sync) if status == "idle"
        sync.update_columns(status: status, attempts: (status == "failed" ? 7 : 0), next_attempt_at: nil,
                            blocked_reasons: (status == "blocked" ? [ "missing_diagnosis" ] : []))
        [ request, sync.reload ]
      end

      { "idle" => "idle", "queued" => "queued", "blocked" => "blocked", "rejected" => "rejected", "failed" => "failed" }.each do |status, kept|
        it "#{status} sem mudança de conteúdo → #{kept}" do
          request, = row_in(status)
          travel 1.minute
          expect { expect(recompute(request).status).to eq(kept) }.not_to change { queued_events.count }
        end

        it "#{status} com conteúdo novo → queued" do
          request, before = row_in(status)
          decide!(request, "return")
          sync = recompute(request)
          expect(sync).to have_attributes(status: "queued", desired_status: "returned-to-requester", blocked_reasons: [])
          expect(sync.desired_digest).not_to eq(before.desired_digest)
          next if status == "queued"

          expect(sync).to have_attributes(attempts: 0, next_attempt_at: Time.current)
          expect(queued_events.where("payload->>'regulation_rnds_sync_id' = ?", sync.id).count).to eq(2)
        end
      end
    end

    # Review Focus 2: autorizado → agendado → 1ª falta → pendente →
    # reautorizado, tudo antes do envio: sai `absence` e depois só o estado
    # final; a `pending` intermediária se junta.
    it "duas mudanças antes do envio, com falta no meio → passo absence e depois o estado final" do
      request = reauthorize!(municipal_request!, offer: offer)
      accept!(recompute(request))
      schedule!(request)
      miss!(request)
      reauthorize!(request.reload, offer: offer)

      sync = recompute(request)
      missed_at = request.reload.events.select { |e| e.status == "missed" }.sole.created_at
      expect(sync).to have_attributes(status: "queued", desired_status: "pending",
                                      pending_steps: [ { "status" => "absence", "at" => missed_at.iso8601(6) } ])

      sync = accept!(sync, step: true)
      expect(sync).to have_attributes(sent_status: "absence", pending_steps: [])
      sync = recompute(request)
      expect(sync).to have_attributes(status: "queued", desired_status: "pending", pending_steps: [])
    end
  end

  describe ".affected_request_ids" do
    it "regulation_request.* → o pedido; settings → :all" do
      id = SecureRandom.uuid
      expect(described_class.affected_request_ids("regulation_request.authorized", regulation_request_id: id)).to eq([ id ])
      expect(described_class.affected_request_ids("care_regulation.settings_changed", user_id: id)).to eq(:all)
      expect(described_class.affected_request_ids("regulation_rnds.settings_changed", user_id: id)).to eq(:all)
    end

    it "care_offer.changed → os pedidos autorizados na oferta; care_provider.changed → pela oferta e pelo care_provider_id" do
      authorized = reauthorize!(municipal_request!, offer: offer)
      other_offer = offer!(provider: external_provider!)
      elsewhere = reauthorize!(municipal_request!, offer: other_offer)
      scheduled_there = schedule!(reauthorize!(municipal_request!, offer: other_offer))
      expect(scheduled_there.care_provider_id).to eq(offer.care_provider_id)

      expect(described_class.affected_request_ids("care_offer.changed", care_offer_id: offer.id)).to eq([ authorized.id ])
      expect(described_class.affected_request_ids("care_provider.changed", care_provider_id: offer.care_provider_id))
        .to contain_exactly(authorized.id, scheduled_there.id)
      expect(described_class.affected_request_ids("care_offer.changed", care_offer_id: other_offer.id))
        .to contain_exactly(elsewhere.id, scheduled_there.id)
    end

    it "health_unit.changed → unidade solicitante, prestador own da unidade e horários na unidade; appointment.* → origem" do
      own = own_authorized_request!
      requested_here = regulation_request!(unit: own.fetch(:unit))
      appointment = schedule_regulated!(own.fetch(:appointment_request), at: 3.days.from_now.change(hour: 9))

      expect(described_class.affected_request_ids("health_unit.changed", health_unit_id: own.fetch(:unit).id))
        .to contain_exactly(own.fetch(:regulation_request).id, requested_here.id)
      expect(described_class.affected_request_ids("health_unit.changed", health_unit_id: own.fetch(:regulation_request).requester_unit_id))
        .to eq([ own.fetch(:regulation_request).id ])
      expect(described_class.affected_request_ids("appointment.scheduled", appointment_id: appointment.id,
                                                                           appointment_request_id: own.fetch(:appointment_request).id))
        .to eq([ own.fetch(:regulation_request).id ])
      expect(described_class.affected_request_ids("appointment.cancelled", appointment_id: SecureRandom.uuid)).to eq([])
    end
  end

  # Task 12 (carry 4 e 7): o livro das remessas como o envio o usa.
  describe "remessas do envio (Task 12)" do
    it "unanswered_delivery?: a remessa delete e a fechada com o marcador not_found não contam" do
      sync = recompute(municipal_request!)
      RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "delete", rnds_id: "dup-1", sent_at: Time.current)
      expect(described_class.unanswered_delivery?(sync)).to be(false)
      RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: "pending", digest: sync.desired_digest,
                                     sent_at: Time.current, error_codes: [ Regulation::RndsReconcile::NOT_FOUND ])
      expect(described_class.unanswered_delivery?(sync)).to be(false)
      RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "create", mira_status: "pending", digest: sync.desired_digest,
                                     sent_at: Time.current, error_codes: [ Regulation::RndsDelivery::GAVE_UP ])
      expect(described_class.unanswered_delivery?(sync)).to be(true) # desistir não diz que não chegou
    end

    it "passo (absence) recusado + evento sem mudança → segue rejected; conteúdo novo → queued" do
      request = reauthorize!(municipal_request!, offer: offer)
      accept!(recompute(request))
      schedule!(request)
      miss!(request)
      reauthorize!(request.reload, offer: offer)
      sync = recompute(request)
      step = sync.pending_steps.first
      digest = Regulation::RiraBundle.digest(Regulation::RiraBundle.for(request: request.reload, sync: sync, status: step, now: Time.current))
      RegulationRndsDelivery.create!(regulation_rnds_sync: sync, kind: "replace", mira_status: "absence", digest: digest,
                                     sent_at: Time.current, http_status: 422, error_codes: [ "EHR-ERR999" ])
      sync.update!(status: "rejected", last_error_codes: [ "EHR-ERR999" ])
      travel 1.second

      expect(recompute(request)).to have_attributes(status: "rejected")
      request.requester_unit.update!(cnes: regulation_cnes) # muda o passo recusado (o CNES do solicitante)
      expect(recompute(request)).to have_attributes(status: "queued")
    end
  end
end
