# Proposta de bloqueio de transmissão a partir da notificação (módulo 35a,
# ADR 0054; contrato §8, decisões 27 e 28; Q8, Q13(6); Review Focus 3). Quem
# chama (VectorControl::ProposeBlockJob) já conferiu o gate, o estado
# `notified` e a doença em block_diseases. Tudo sob a trava consultiva
# `vector_control:transmission_blocks` (Support.serialize!), que vale até o
# fim da transação de fora: duas notificações vizinhas ao mesmo tempo → a
# segunda espera, vê a proposta da primeira e entra nela; nunca duas propostas
# para a mesma área na janela.
#   - notificação que já é caso de bloqueio → nada (o índice único é a
#     última palavra);
#   - resident_elsewhere → só a tarefa case_resident_elsewhere (uma por
#     notificação) e fim;
#   - lugar (CasePlace): cadastro individual ativo → domicílio → quarteirão
#     do perfil;
#   - com lugar: entra no bloqueio proposed/active, o mais antigo, cuja área
#     tem o quarteirão (proposta sem área: Rings.around([centro],
#     block_radius_rings)) e cujo caso mais recente tem case_on ≥ case_on do
#     novo − block_grouping_days (added_by job); senão nasce a proposta com o
#     quarteirão como centro (a área sugerida sai dos anéis, sem linha);
#   - sem lugar: sempre proposta própria, sem centro, e a tarefa
#     block_case_without_place.
# Número do caso (Q13(6)): o maior da cidade + 1, sob a mesma trava (sem
# buraco quando a transação volta atrás; o índice único barra repetição); o
# trigger o mantém fixo. `transmission_block.proposed` só na criação e
# `vector_task.opened` nas tarefas, só com ids.
module VectorControl
  module Blocks
    module Propose
      DISEASE_GROUP = "arbovirus".freeze
      PROPOSED = "transmission_block.proposed".freeze
      TASK_OPENED = "vector_task.opened".freeze
      ELSEWHERE = "case_resident_elsewhere".freeze
      WITHOUT_PLACE = "block_case_without_place".freeze

      module_function

      # parameters: os valores vigentes (Parameters.current.values).
      # -> Result.ok(block:, case:) (nil, nil quando nada entra em bloqueio)
      def call(notification:, parameters:)
        ApplicationRecord.transaction(requires_new: true) do
          Support.serialize!
          next Result.ok(block: nil, case: nil) if TransmissionBlockCase.exists?(disease_notification_id: notification.id)
          next elsewhere(notification) if notification.resident_elsewhere

          place = CasePlace.block(notification.patient_id)
          block = place && grouping(place, notification.suspected_on, parameters)
          created = block.nil?
          block ||= TransmissionBlock.create!(disease_group: DISEASE_GROUP, center_block_id: place)
          row = TransmissionBlockCase.create!(transmission_block: block, disease_notification_id: notification.id,
                                              case_on: notification.suspected_on, added_by: "job",
                                              number: TransmissionBlockCase.maximum(:number).to_i + 1)
          if created
            DomainEvents.publish(PROPOSED, transmission_block_id: block.id)
            open_task!(kind: WITHOUT_PLACE, transmission_block_id: block.id) unless place
          end
          Result.ok(block: block, case: row)
        end
      end

      def elsewhere(notification)
        unless VectorTask.exists?(kind: ELSEWHERE, disease_notification_id: notification.id)
          open_task!(kind: ELSEWHERE, disease_notification_id: notification.id)
        end
        Result.ok(block: nil, case: nil)
      end

      # O bloqueio aberto mais antigo com caso na janela e o quarteirão na área.
      def grouping(place, case_on, parameters)
        since = case_on - parameters.fetch("block_grouping_days").to_i
        recent = TransmissionBlockCase.group(:transmission_block_id).having("MAX(case_on) >= ?", since).select(:transmission_block_id)
        candidates = TransmissionBlock.where(status: Support::OPEN, id: recent).order(:created_at, :id).to_a
        return nil if candidates.empty?

        areas = TransmissionBlockArea.where(transmission_block_id: candidates.map(&:id)).pluck(:transmission_block_id, :city_block_id)
        with_area = areas.to_set(&:first)
        rings = parameters.fetch("block_radius_rings").to_i
        candidates.find do |block|
          if with_area.include?(block.id)
            areas.include?([ block.id, place ])
          else
            block.center_block_id && Rings.around([ block.center_block_id ], rings: rings).include?(place)
          end
        end
      end

      def open_task!(**attrs)
        task = VectorTask.create!(**attrs)
        DomainEvents.publish(TASK_OPENED, vector_task_id: task.id)
        task
      end
      private_class_method :elsewhere, :grouping, :open_task!
    end
  end
end
