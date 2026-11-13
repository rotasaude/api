# ADR 0026 (spec §4.4): o municipal_admin confirma a exclusão (o step-up fica
# no controller). Numa transação só, com trava no pedido e nos pares do CPF:
# reconfere a retenção pela mesma regra do pedido (atendimento, documento ou
# exame chegado depois do pedido vira `retained`, nada mais muda); senão,
# para cada par, revoga, anonimiza, apaga o apagável e troca CPF e telefone
# por um marcador que não identifica ninguém.
# ADR 0028: também o CNS do CADSUS e a consulta pendente.
# ADR 0031: também o nome completo, o social e o da mãe.
# ADR 0039 (D-U1): e raça/cor, etnia e endereço do paciente do CPF.
# ADR 0040: e a condição declarada e as sugestões de linha de cuidado.
# ADR 0048: e os avisos de viagem do par; séries suspensas, o paciente fora
# das viagens abertas e os passageiros anonimizados (Transport::Anonymize).
# ADR 0049: e o encaminhamento e o acolhimento do CAPS sem registro de saúde
# anonimizados (Psychosocial::Anonymize).
# ADR 0050: e o nome, o nascimento, o sexo e o CNS do paciente não retido (a
# evasão da UPA antes da classificação deixa o `walk_in` só com ids); o CPF
# do paciente fica (coluna de identidade, rota_patient_guard).
# ADR 0051: e as manifestações da ouvidoria desligadas do par, com a
# identidade copiada para a manifestação (registro de obrigação legal retido);
# os avisos da ouvidoria apagados.
# ADR 0052: visita domiciliar e participação em atividade coletiva retêm (pelo
# examined_patients?, sob a trava do paciente); a exclusão nunca as apaga.
# Reasons: :not_pending, :own_request, :patient_on_trip, :patient_in_urgency.
module Citizens
  module Erase
    TOMBSTONE_PREFIX = "erased:".freeze
    # ADR 0050: a identificação do paciente não retido, apagada com o par. O
    # CPF não entra: o rota_patient_guard nunca deixa trocá-lo.
    PATIENT_IDENTITY = %w[full_name social_name mother_name birth_date sex cns].freeze
    MAX_ATTEMPTS = 3

    # Um pedido do par mudou de unidade entre a trava das unidades e a dos pares.
    class UnitsChanged < StandardError; end

    module_function

    def call(request:, by:)
      attempts = 0
      begin
        attempt(request: request, by: by)
      rescue UnitsChanged
        attempts += 1
        raise if attempts >= MAX_ATTEMPTS

        request.reload
        retry
      end
    end

    def attempt(request:, by:)
      result = nil
      ApplicationRecord.transaction do
        request.lock!
        next result = Result.fail(:not_pending) unless request.status == "pending"
        next result = Result.fail(:own_request) if request.requested_by_user_id == by.id

        # Ordem global de travas: unidade FOR SHARE → cidadão → sugestões de
        # linha de cuidado → séries e viagens abertas → paciente → horários → pedido.
        # A exclusão escreve pedidos do par (nota do remarque, CloseRevoked) e
        # trava o cidadão em FOR UPDATE (segura a FK de um atendimento novo
        # enquanto reconfere a retenção). Sem a unidade na frente, cruzava com o
        # HealthUnits::Drain, que segura o pedido e espera o cidadão (FK do
        # pedido novo) — deadlock. Com a unidade em FOR SHARE, o Drain espera.
        locked_units = lock_units!(RequestErasure.pairs_of(request.cpf).order(:id).to_a)
        pairs = RequestErasure.pairs_of(request.cpf).order(:id).lock.to_a
        # Pares travados: nenhum pedido novo nasce para eles (FK). Se um pedido
        # entrou noutra unidade antes da trava, recomeça com ela na frente.
        raise UnitsChanged unless (unit_ids_of(pairs) - locked_units).empty?
        # A regra do RequestErasure.retained?, em dois passos. Primeiro o que
        # tem FK para o par (atendimento, documento), protegido pela trava do
        # par. Só sem eles trava o paciente: quem trava o paciente antes do
        # cidadão (documento, consulta, adendo) exige atendimento, que já reteve
        # no primeiro passo — a ordem fica sempre cidadão → paciente. O paciente
        # travado segura a FK de um exame novo enquanto o exame é conferido.
        pair_scope = Citizen.where(id: pairs.map(&:id))
        patient_ids = RequestErasure.patient_ids(pair_scope, cpf: request.cpf)
        # ADR 0040: as sugestões de linha de cuidado que a exclusão apaga (dos
        # pares e do paciente), travadas por id ANTES do paciente — a ordem do
        # CareLines::Enroll (pares em FOR KEY SHARE → sugestões → paciente: o
        # Enroll trava os pares antes de tudo, pela conferência de paciente
        # anonimizado, e o Erase já os tem travados acima). O aceite que
        # trava antes termina e a inscrição dele retém abaixo; o que chega
        # depois acha a sugestão apagada.
        CareLineSuggestion.where(citizen_id: pairs.map(&:id)).or(CareLineSuggestion.where(patient_id: patient_ids))
                          .order(:id).lock.to_a
        locked_patients = []
        retained = RequestErasure.clinical_on_pairs?(pair_scope)
        unless retained
          # ADR 0048: séries e viagens abertas do paciente ANTES do paciente
          # (a ordem do MaterializeSeriesJob e do AddPassenger: série/viagem →
          # FK do paciente). O Transport::Notify trava cidadão → viagem: o
          # cidadão já está travado acima, sem inversão.
          Transport::Anonymize.lock!(patient_ids)
          # ADR 0049: os encaminhamentos ao CAPS ANTES do paciente (a ordem do
          # Psychosocial::RecordReception: encaminhamento → FK do paciente).
          Psychosocial::Anonymize.lock!(patient_ids)
          locked_patients = Patient.where(id: patient_ids).order(:id).lock.to_a
          retained = RequestErasure.examined_patients?(patient_ids)
        end
        # ADR 0048 (Ruling I1): paciente ativo numa viagem em andamento (viagem
        # travada no lock! acima) — nada muda, o pedido segue pendente; o admin
        # tenta de novo depois do fechamento (viagem dura até 72 h).
        next result = Result.fail(:patient_on_trip) if !retained && Transport::Anonymize.on_trip?(patient_ids)
        # ADR 0050: atendimento `walk_in` aberto na UPA (o paciente travado
        # acima segura uma chegada nova) — nada muda, o pedido segue pendente;
        # o admin tenta de novo depois do desfecho.
        next result = Result.fail(:patient_in_urgency) if !retained && RequestErasure.urgency_open?(patient_ids)
        # O banco não exige decided_by_user: quem decide é gravado aqui, sempre.
        if retained
          request.update!(status: "retained", decided_by_user: by, decided_at: Time.current)
          DomainEvents.publish("citizen.erasure_retained", request_id: request.id)
          next result = Result.ok(request: request)
        end

        # Horários vivos do par travados ANTES de qualquer escrita em pedido:
        # Lapse/Confirm/CancelByCitizen travam o horário e depois o pedido.
        # Quem grava linha com FK para o cidadão depois do horário (o aviso do
        # Remind) trava o cidadão ANTES do horário, e espera esta exclusão.
        live = Appointment.live.where(citizen_id: pairs.map(&:id)).order(:id).lock.to_a
        pairs.each { |citizen| erase_pair(citizen, live.select { |a| a.citizen_id == citizen.id }) }
        # D-U1 (ADR 0039): o paciente não retido perde raça/cor, etnia e endereço junto com o par.
        # ADR 0050: e nome, nascimento, sexo e CNS (a chave de duplicados vai junto, pelo Patient).
        locked_patients.each { |patient| patient.update!(erased_patient_attrs(patient)) }
        # ADR 0040: sugestões do paciente não retido (sem inscrição, por definição).
        CareLineSuggestion.where(patient_id: locked_patients.map(&:id)).delete_all
        # ADR 0048 (Desvio 17; T23): séries suspensas, o paciente fora das
        # viagens abertas e os passageiros anonimizados (presença e contagens ficam).
        Transport::Anonymize.patients!(locked_patients.map(&:id), by: by)
        # ADR 0049 (P17): encaminhamento e acolhimento do CAPS (sem matrícula,
        # ação, permanência nem matriciamento, por definição) anonimizados.
        Psychosocial::Anonymize.patients!(locked_patients.map(&:id))
        # O trigger aceita a troca do cpf só nesta mesma UPDATE, mas não a
        # exige: o pedido confirmado deixa de guardar o CPF por causa daqui.
        request.update!(status: "confirmed", decided_by_user: by, decided_at: Time.current, cpf: tombstone)
        DomainEvents.publish("citizen.erased", request_id: request.id)
        result = Result.ok(request: request)
      end
      result
    end

    # ADR 0050: o provisório identificado por paciente novo (a própria linha
    # recebeu o CPF; unidentified false) ainda guarda a descrição da chegada —
    # sai junto. O provisório FUNDIDO (unidentified, sem CPF) nunca chega aqui
    # e fica como está (ck_patients_description).
    def erased_patient_attrs(patient)
      attrs = (Patient::DEMOGRAPHICS + PATIENT_IDENTITY).index_with(nil)
      attrs["unidentified_description"] = nil if !patient.unidentified && patient.unidentified_description.present?
      attrs
    end

    def erase_pair(citizen, live_appointments)
      phones = phone_variants(citizen.phone)

      # ADR 0029: o texto livre do remarque sai de todos os pedidos do par; dos vivos, ANTES da
      # revogação (que fecha os abertos).
      noted = AppointmentRequest.where(citizen_id: citizen.id).where.not(reschedule_note: nil)
      noted.live_requests.update_all(reschedule_note: nil, updated_at: Time.current)
      # No encerrado o trigger só aceita a nota indo a NULL, sem nenhuma outra
      # coluna junto (nem updated_at).
      noted.where(status: "closed").update_all(reschedule_note: nil)

      # Conversas do par: as dele (web) e as do WhatsApp do telefone, que não
      # têm citizen_id. Uma conversa web de OUTRO cidadão no mesmo celular (a
      # família) não é deste par e fica intacta.
      conversations = Conversation.where(citizen_id: citizen.id)
                                  .or(Conversation.where(citizen_id: nil, phone: phones))
      conversations.find_each do |conversation|
        RevokeConsent.call(conversation: conversation, origin: "erasure") if conversation.active_consent
        # Nenhuma triagem tem atendimento (reconferido acima, sob trava): todas
        # se limpam, sem a checagem de Triages::Anonymize.call.
        Triage.where(conversation_id: conversation.id).find_each { |t| Triages::Anonymize.clear!(t) }
        conversation.update_columns(phone: tombstone, updated_at: Time.current)
      end

      # ADR 0051: os anexos órfãos que as sessões do par subiram, antes de as
      # sessões sumirem (o anexo guarda só o id da sessão).
      Ombudsman::Erasure.purge_orphan_uploads!(CitizenSession.where(phone: phones))
      # Não há chave estrangeira nem trigger que segure estes DELETEs
      # (campaign_recipients_append_only deixa o DELETE passar de propósito).
      CitizenSession.where(phone: phones).delete_all
      OtpChallenge.where(phone: phones).delete_all
      InboundMessage.where(from: phones).delete_all
      OutboundMessage.where(to: phones).delete_all
      CitizenVerificationCode.where(citizen_id: citizen.id).delete_all
      CitizenContactPreference.where(citizen_id: citizen.id).delete_all
      CampaignRecipient.where(citizen_id: citizen.id).delete_all
      # ADR 0027 (spec 2026-10-05 §5.5): as sugestões do par (o trigger deixa o
      # DELETE passar de propósito).
      TriageSuggestion.where(citizen_id: citizen.id).delete_all
      # ADR 0040: a condição declarada (dado pessoal, nunca diagnóstico) e as
      # sugestões de linha de cuidado do par (os triggers deixam o DELETE
      # passar). A inscrição retém e nunca chega aqui.
      CitizenDeclaredCondition.where(citizen_id: citizen.id).delete_all
      CareLineSuggestion.where(citizen_id: citizen.id).delete_all
      # ADR 0029: os avisos de lembrete do par (o trigger deixa o DELETE passar).
      AppointmentNotice.where(citizen_id: citizen.id).delete_all
      # ADR 0048: os avisos de viagem do par (o trigger deixa o DELETE passar).
      TransportTripNotice.where(citizen_id: citizen.id).delete_all
      # ADR 0030 (api#43): conteúdo e códigos da fila LEDI das fontes do par.
      Ledi::CitizenSources.scrub!([ citizen.id ])
      # ADR 0051 (Q5, Q46): as manifestações da ouvidoria desligadas do par
      # (travadas depois do par: cidadão → manifestação, a ordem do
      # Ombudsman::Lock) e a identidade nos manifestant_* nulos; os avisos da
      # ouvidoria saem e a satisfação fica. ANTES do marcador: nome, CPF e
      # telefone ainda estão no par.
      Ombudsman::Erasure.unlink!(citizen)

      # ADR 0028: o CNS do CADSUS, a marca e a consulta pendente saem junto.
      # update_columns cifra (o tipo cifrado serializa); um marcador por coluna,
      # para não repetir valor entre cpf e phone.
      citizen.update_columns(cpf: tombstone, phone: tombstone, neighborhood_id: nil, erased_at: Time.current,
                             birth_date: nil, sex: nil, gender_identity: nil, profile_source: nil,
                             cns: nil, cadsus_checked_at: nil, cadsus_pending_cns: nil,
                             full_name: nil, social_name: nil, mother_name: nil, cadsus_pending_session_id: nil, cadsus_pending_at: nil, updated_at: Time.current)

      end_live_bookings(citizen, live_appointments)
    end

    # ADR 0029 (pré-merge PM-B item 4): a casca não fica com horário nem pedido
    # vivo — sem lembrete, sem vencimento/falta reabrindo o pedido, fora da
    # fila. Horários (já travados) antes dos pedidos; o motivo fixo fica só no
    # horário, o evento leva ids.
    def end_live_bookings(citizen, live_appointments)
      now = Time.current
      live_appointments.each do |appointment|
        appointment.update!(status: "cancelled_by_citizen", cancel_reason: Appointment::ERASURE_CANCEL_REASON,
                            ended_at: now)
        DomainEvents.publish("appointment.cancelled", appointment_id: appointment.id, by: "erasure")
      end
      AppointmentRequest.where(citizen_id: citizen.id).live_requests.order(:id).lock.each do |request|
        AppointmentRequests::Lifecycle.close!(request, reason: "consent_revoked")
      end
    end

    # Trava FOR SHARE (por id) as unidades dos pedidos que a exclusão vai
    # escrever, até o conjunto parar de mudar (um Drain que commitou enquanto
    # esperávamos levou o pedido para outra unidade). Devolve os ids travados.
    def lock_units!(pairs)
      locked = []
      loop do
        missing = unit_ids_of(pairs) - locked
        return locked if missing.empty?

        HealthUnit.where(id: missing).order(:id).lock("FOR SHARE").to_a
        locked += missing
      end
    end

    # Unidades dos pedidos vivos que erase_pair escreve: os do par (nota do
    # remarque) e os de triagem ligados às conversas do par (CloseRevoked).
    def unit_ids_of(pairs)
      return [] if pairs.empty?

      citizen_ids = pairs.map(&:id)
      phones = pairs.flat_map { |citizen| phone_variants(citizen.phone) }
      conversations = Conversation.where(citizen_id: citizen_ids).or(Conversation.where(citizen_id: nil, phone: phones))
      triage_ids = Triage.where(conversation_id: conversations.select(:id)).select(:id)
      linked = AppointmentRequestTriage.where(triage_id: triage_ids).select(:request_id)
      live = AppointmentRequest.live_requests
      live.where(citizen_id: citizen_ids).or(live.where(origin_triage_id: triage_ids)).or(live.where(id: linked))
          .where.not(target_unit_id: nil).distinct.pluck(:target_unit_id).sort
    end

    # O cadastro web guarda "+55…"; o WhatsApp grava o que a Meta manda, só
    # dígitos, sem "+". Os dois formatos são o mesmo telefone.
    def phone_variants(phone) = [ phone, phone.delete_prefix("+") ].uniq

    # Marcador sem identidade; também usado por RejectErasure.
    def tombstone = "#{TOMBSTONE_PREFIX}#{SecureRandom.uuid}"
  end
end
