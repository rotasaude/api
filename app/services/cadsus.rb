# CADSUS (ADR 0028; spec 2026-10-05 §7; pesquisa frente 2). Do retorno só
# interessam CNS, nascimento e sexo, e só o CNS chega a ser gravado (depois da
# confirmação do atendente). Nome, mãe e endereço nunca saem do cliente.
module Cadsus
  class Error < StandardError; end
  class Unauthorized < Error; end
  class Unavailable < Error; end

  Record = Data.define(:cns, :birth_date, :sex)
end
