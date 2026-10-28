# Diagnóstico do pedido de regulação (contrato §13 G10 corrigido pelo G12): a
# regra num serviço só, consumida pelo rascunho, pelo complemento e pela
# promoção. Chamado DEPOIS de Requesters.check.
#
# - médico: `cid10` obrigatório (`ciap2` opcional);
# - enfermeiro e dentista: pelo menos um entre `cid10` (só se o CBO puder
#   registrar CID-10, Ledi::ConsultationMapping.cid10_allowed?) e `ciap2`;
# - `kept_cid10`: o CID-10 que já estava no pedido (complemento) conta e não é
#   recusado, mesmo que o CBO não possa registrá-lo.
# Códigos validados pelas releases ativas de ClinicalTerms (as mesmas dos
# problemas da consulta) e devolvidos normalizados (maiúsculo, sem ponto).
module CareRegulation
  module Diagnosis
    module_function

    # -> Result.ok(cid10: String|nil, ciap2: String|nil) | fail(reason, details: { path: })
    def check(cbo:, cid10:, ciap2:, kept_cid10: nil)
      { "cid10" => cid10, "ciap2" => ciap2 }.each do |key, value|
        return refuse(:invalid_request, key) unless value.nil? || value.is_a?(String)
      end
      cid10 = cid10.presence
      ciap2 = ciap2.presence
      cid10_code = cid10 && ClinicalTerms.find("cid10", cid10)
      return refuse(:invalid_cid10, "cid10") if cid10 && !cid10_code

      ciap2_code = ciap2 && ClinicalTerms.find("ciap2", ciap2)
      return refuse(:invalid_ciap2, "ciap2") if ciap2 && !ciap2_code

      kind = Requesters.kind(cbo)
      cid10 = cid10_code&.code
      kept = kept_cid10.is_a?(String) && kept_cid10.present? ? ClinicalTerms.normalize(kept_cid10) : nil
      cid10 ||= kept
      allowed = Ledi::ConsultationMapping.cid10_allowed?(cbo)

      if kind == :physician
        return refuse(:diagnosis_required, "cid10") unless cid10
      elsif cid10 && !allowed && cid10 != kept
        return refuse(:cid10_not_allowed_for_cbo, "cid10")
      elsif cid10.nil? && ciap2_code.nil?
        return refuse(:diagnosis_required, allowed ? "cid10" : "ciap2")
      end

      Result.ok(cid10: cid10, ciap2: ciap2_code&.code)
    end

    def refuse(reason, path) = Result.fail(reason, details: { path: path })
    private_class_method :refuse
  end
end
