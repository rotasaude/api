# Exclusão LGPD na ouvidoria (ADR 0026; ADR 0051; contrato §13 corrigido por
# §16 Q5, Q46, Q56 e Q57). Chamado do Citizens::Erase#erase_pair, com o par
# já travado FOR UPDATE e ANTES de o par virar marcador (o nome, o CPF e o
# telefone ainda estão nele). A manifestação é registro de obrigação legal e
# fica, desligada do par: citizen_id vai a nulo e a identidade passa aos
# `manifestant_*` — o nome de exibição (o social, quando houver: o direito ao
# nome social continua, Q56) a manifestant_name, o CPF a manifestant_cpf e o
# telefone a manifestant_phone (Q57; manifestant_contact é o contato que a
# equipe digita e nunca recebe o telefone do par). A trava segue a ordem de
# toda ação da ouvidoria (Ombudsman::Lock): cidadão → manifestação.
#
# Q46: só os `manifestant_*` nulos recebem o valor do par (o COALESCE). O nome
# declarado do par sem consentimento (U1) nunca é sobrescrito; e um valor já
# gravado nunca é regravado — o trigger compara a cifra, e a cifra nova do
# mesmo texto seria outra.
#
# Os avisos da ouvidoria do par saem (o trigger deixa o DELETE passar); a
# pesquisa de satisfação fica (não tem o cidadão).
module Ombudsman
  module Erasure
    module_function

    def unlink!(citizen)
      identity = { manifestant_name: citizen.display_name, manifestant_cpf: citizen.cpf, manifestant_phone: citizen.phone }.compact
      now = Time.current
      OmbudsmanManifestation.where(citizen_id: citizen.id).order(:id).lock.each do |manifestation|
        missing = identity.select { |column, _| manifestation.public_send(column).nil? }
        manifestation.update_columns(**missing, citizen_id: nil, updated_at: now)
      end
      OmbudsmanNotice.where(citizen_id: citizen.id).delete_all
    end
  end
end
