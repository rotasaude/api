# O mantenedor da API de manutenção como ator de um command de cidade.
#
# D6: o superusuário pula a AUTORIZAÇÃO — papéis e memberships — e nada mais.
# Por isso a única coisa que este objeto responde de diferente de um User é
# `has_role?`: toda policy (ApplicationPolicy#role?) pergunta ao ator, e o
# mantenedor diz sim.
#
# As regras de domínio que existem para PRENDER o mantenedor olham
# `actor_kind`, nunca o papel: ele não assina protocolo, não concede nem
# convida quem assina ou quem concede (spec de assinaturas §7). Perguntar o
# papel a este objeto é sempre "sim" — por isso a pergunta certa é o tipo.
#
# O mantenedor NÃO é um User da cidade, e não vira um: um User de sistema por
# cidade faria mantenedores diferentes parecerem a mesma pessoa na trilha.
module Maintenance
  class MaintainerActor
    attr_reader :maintainer

    def initialize(maintainer)
      @maintainer = maintainer
    end

    def id = maintainer.id
    def actor_kind = "maintainer"
    def has_role?(_role) = true
  end
end
