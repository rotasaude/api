# Prestação de contas do TFD (contrato §6; §14 T8, T13): a comissão (o step-up
# é da rota) anexa o comprovante e o processo vai a `completed`.
#   corpo   { content_type, data (base64), filename? } — PDF/JPEG/PNG até 10 MB
#           pelos bytes mágicos (Tfd::Files → Exams::Files); `filename` 1..120,
#           cifrado; o api gera um se faltar;
#   recusas invalid_request (chave de fora, filename), invalid_file,
#           invalid_transition (só `travelling`), legs_pending (algum trecho
#           sem `done_at` e não anulado — FR I1).
# O arquivo só é gravado depois de todas as conferências, na mesma transação
# da prestação, da transição e do evento tfd.accountability_closed (só ids).
module Tfd
  module CloseAccountability
    KEYS = %w[content_type data filename].freeze

    module_function

    # -> Result.ok(tfd_case:, accountability:) | fail(:missing_role | :invalid_request | :invalid_file | :invalid_transition | :legs_pending)
    def call(tfd_case:, attrs:, by:)
      return Result.fail(:missing_role) unless Access.committee?(by)

      attrs = attrs.to_h.stringify_keys
      unknown = (attrs.keys - KEYS).map { |key| key.to_s[0, 64] }
      name = attrs["filename"]
      unknown << "filename" if attrs.key?("filename") && !name.nil? && Transport::Support.text(name, 1..Transport::Catalog::TEXT_MAX).nil?
      return Transport::Support.refuse(unknown) if unknown.any?

      bytes = Files.decode(attrs["data"], attrs["content_type"])
      return Result.fail(:invalid_file) unless bytes

      TfdCase.transaction(requires_new: true) do
        tfd_case.lock!
        next Result.fail(:invalid_transition) unless tfd_case.status == "travelling"
        next Result.fail(:legs_pending) if tfd_case.tfd_legs.where(done_at: nil, voided_at: nil).exists?

        stored = Files.store(bytes: bytes, content_type: attrs["content_type"], user: by)
        next stored if stored.failure?

        file = stored.payload.fetch(:file)
        filename = name.nil? ? Files.generated_name(file) : Transport::Support.text(name, 1..Transport::Catalog::TEXT_MAX)
        accountability = TfdAccountability.create!(tfd_case: tfd_case, exam_file: file, filename: filename, closed_at: Time.current,
                                                   closed_by_user: by)
        moved = Transition.call(tfd_case: tfd_case, to: "completed", by: by)
        raise "tfd: travelling → completed refused" if moved.failure? # inalcançável: conferida sob a trava

        DomainEvents.publish("tfd.accountability_closed", tfd_case_id: tfd_case.id, user_id: by.id)
        Result.ok(tfd_case: tfd_case, accountability: accountability)
      end
    end
  end
end
