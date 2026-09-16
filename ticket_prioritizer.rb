# frozen_string_literal: true

# app/services/queue_pilot/ticket_prioritizer.rb
#
# QueuePilot
# -------------------------------------------------------------------
# Motor de priorização de tickets para equipes de suporte/operações.
#
# O objetivo não é simplesmente classificar tickets por um campo
# "priority". O serviço considera:
#
# - proximidade do vencimento do SLA;
# - impacto operacional;
# - urgência;
# - quantidade de usuários afetados;
# - tempo esperando atendimento;
# - reaberturas;
# - cliente estratégico;
# - existência de bloqueios;
# - recorrência do mesmo incidente;
# - sobrecarga do responsável;
# - compatibilidade de habilidades para sugerir outro responsável;
# - proteção contra starvation de tickets antigos.
#
# O resultado também é EXPLICÁVEL:
# cada ticket recebe os motivos que fizeram sua pontuação subir
# ou descer.
#
# Este arquivo foi pensado propositalmente como código isolado de
# portfólio. Ele pressupõe a existência dos modelos Ticket, Agent e
# TicketPriorityAudit.
#
# -------------------------------------------------------------------

module QueuePilot
  class TicketPrioritizer
    DEFAULT_BATCH_SIZE = 200

    PRIORITY_LEVELS = {
      critical: 90,
      high: 70,
      medium: 45,
      low: 20
    }.freeze

    IMPACT_WEIGHTS = {
      critical: 24.0,
      high: 18.0,
      medium: 10.0,
      low: 4.0,
      unknown: 0.0
    }.freeze

    URGENCY_WEIGHTS = {
      immediate: 22.0,
      high: 16.0,
      medium: 9.0,
      low: 3.0,
      unknown: 0.0
    }.freeze

    CUSTOMER_TIER_WEIGHTS = {
      strategic: 8.0,
      enterprise: 6.0,
      business: 3.0,
      standard: 0.0
    }.freeze

    STATUS_ELIGIBLE_FOR_PRIORITIZATION = %w[
      new
      open
      pending
      investigating
      waiting_internal
    ].freeze

    CLOSED_STATUSES = %w[
      solved
      closed
      cancelled
    ].freeze

    Result = Data.define(
      :ticket_id,
      :score,
      :priority,
      :risk,
      :confidence,
      :current_assignee_id,
      :recommended_assignee_id,
      :overloaded_assignee,
      :sla_remaining_minutes,
      :reasons,
      :warnings,
      :metadata
    )

    TicketSnapshot = Data.define(
      :ticket,
      :now,
      :age_minutes,
      :waiting_minutes,
      :sla_total_minutes,
      :sla_remaining_minutes,
      :sla_consumption_ratio,
      :affected_users,
      :reopen_count,
      :similar_open_incidents,
      :required_skill_ids,
      :current_assignee,
      :current_assignee_load
    )

    AgentCandidate = Data.define(
      :agent,
      :score,
      :skill_score,
      :capacity_score,
      :active_ticket_count,
      :estimated_workload_minutes,
      :reasons
    )

    attr_reader :team,
                :now,
                :persist,
                :batch_size,
                :logger

    def initialize(
      team:,
      now: Time.current,
      persist: false,
      batch_size: DEFAULT_BATCH_SIZE,
      logger: Rails.logger
    )
      @team = team
      @now = now
      @persist = persist
      @batch_size = batch_size
      @logger = logger
    end

    # ---------------------------------------------------------------
    # PUBLIC API
    # ---------------------------------------------------------------

    def call
      instrument("queue_pilot.prioritization.started") do
        results = []

        candidate_scope.find_each(batch_size: batch_size) do |ticket|
          begin
            result = prioritize_ticket(ticket)
            results << result

            persist_result!(ticket, result) if persist
          rescue StandardError => e
            report_ticket_error(ticket, e)
          end
        end

        ranked = rank_results(results)

        instrument(
          "queue_pilot.prioritization.finished",
          processed: ranked.size,
          critical: ranked.count { |result| result.priority == :critical },
          high_risk: ranked.count { |result| result.risk == :high }
        ) {}

        ranked
      end
    end

    def prioritize(ticket)
      result = prioritize_ticket(ticket)
      persist_result!(ticket, result) if persist
      result
    end

    private

    # ---------------------------------------------------------------
    # QUERY
    # ---------------------------------------------------------------

    def candidate_scope
      Ticket
        .where(team_id: team.id)
        .where(status: STATUS_ELIGIBLE_FOR_PRIORITIZATION)
        .includes(
          :customer,
          :assignee,
          :required_skills
        )
        .order(created_at: :asc)
    end

    # ---------------------------------------------------------------
    # PRIORITIZATION PIPELINE
    # ---------------------------------------------------------------

    def prioritize_ticket(ticket)
      snapshot = build_snapshot(ticket)

      reasons = []
      warnings = []

      components = {
        sla: sla_score(snapshot, reasons, warnings),
        impact: impact_score(snapshot, reasons),
        urgency: urgency_score(snapshot, reasons),
        aging: aging_score(snapshot, reasons),
        waiting: waiting_score(snapshot, reasons),
        affected_users: affected_users_score(snapshot, reasons),
        reopen: reopen_score(snapshot, reasons),
        customer: customer_score(snapshot, reasons),
        incident_cluster: incident_cluster_score(snapshot, reasons),
        blocking: blocking_score(snapshot, reasons),
        starvation_protection: starvation_score(snapshot, reasons)
      }

      raw_score = components.values.sum

      overload = assignee_overloaded?(snapshot)

      if overload
        reasons << "Responsável atual está acima da carga operacional recomendada."
        raw_score += 3.0
      end

      final_score = clamp(raw_score.round(2), 0.0, 100.0)

      recommended_agent = find_recommended_agent(
        snapshot,
        overloaded: overload
      )

      confidence = calculate_confidence(snapshot, warnings)

      Result.new(
        ticket_id: ticket.id,
        score: final_score,
        priority: score_to_priority(final_score),
        risk: calculate_risk(snapshot, final_score),
        confidence: confidence,
        current_assignee_id: snapshot.current_assignee&.id,
        recommended_assignee_id: recommended_agent&.agent&.id,
        overloaded_assignee: overload,
        sla_remaining_minutes: snapshot.sla_remaining_minutes,
        reasons: reasons.uniq,
        warnings: warnings.uniq,
        metadata: {
          components: components.transform_values { |value| value.round(2) },
          age_minutes: snapshot.age_minutes,
          waiting_minutes: snapshot.waiting_minutes,
          affected_users: snapshot.affected_users,
          reopen_count: snapshot.reopen_count,
          similar_open_incidents: snapshot.similar_open_incidents,
          current_assignee_load: snapshot.current_assignee_load,
          recommended_agent_score: recommended_agent&.score,
          generated_at: now.iso8601
        }
      )
    end

    # ---------------------------------------------------------------
    # SNAPSHOT
    # ---------------------------------------------------------------

    def build_snapshot(ticket)
      sla_total = calculate_sla_total_minutes(ticket)
      sla_remaining = calculate_sla_remaining_minutes(ticket)

      TicketSnapshot.new(
        ticket: ticket,
        now: now,
        age_minutes: minutes_between(ticket.created_at, now),
        waiting_minutes: waiting_minutes(ticket),
        sla_total_minutes: sla_total,
        sla_remaining_minutes: sla_remaining,
        sla_consumption_ratio: sla_consumption_ratio(
          sla_total,
          sla_remaining
        ),
        affected_users: safe_integer(ticket.affected_users_count, 1),
        reopen_count: safe_integer(ticket.reopen_count, 0),
        similar_open_incidents: similar_incident_count(ticket),
        required_skill_ids: required_skill_ids(ticket),
        current_assignee: ticket.assignee,
        current_assignee_load: calculate_agent_load(ticket.assignee)
      )
    end

    # ---------------------------------------------------------------
    # SLA
    # ---------------------------------------------------------------

    def sla_score(snapshot, reasons, warnings)
      remaining = snapshot.sla_remaining_minutes

      if remaining.nil?
        warnings << "Ticket não possui prazo de SLA configurado."
        return 0.0
      end

      if remaining <= 0
        reasons << "SLA já foi violado."
        return 35.0
      end

      ratio = snapshot.sla_consumption_ratio

      case ratio
      when 0.95..Float::INFINITY
        reasons << "Mais de 95% do prazo de SLA já foi consumido."
        31.0
      when 0.85...0.95
        reasons << "Ticket está muito próximo do vencimento do SLA."
        27.0
      when 0.70...0.85
        reasons << "Ticket entrou na zona de atenção do SLA."
        20.0
      when 0.50...0.70
        12.0
      when 0.25...0.50
        6.0
      else
        2.0
      end
    end

    def calculate_sla_total_minutes(ticket)
      return nil unless ticket.sla_started_at && ticket.sla_due_at

      minutes_between(
        ticket.sla_started_at,
        ticket.sla_due_at
      )
    end

    def calculate_sla_remaining_minutes(ticket)
      return nil unless ticket.sla_due_at

      ((ticket.sla_due_at - now) / 60.0).round
    end

    def sla_consumption_ratio(total, remaining)
      return 0.0 if total.nil?
      return 0.0 if total <= 0
      return 1.0 if remaining.nil?

      consumed = total - remaining

      clamp(
        consumed.to_f / total.to_f,
        0.0,
        2.0
      )
    end

    # ---------------------------------------------------------------
    # IMPACT
    # ---------------------------------------------------------------

    def impact_score(snapshot, reasons)
      impact = normalize_key(snapshot.ticket.impact)

      weight = IMPACT_WEIGHTS.fetch(
        impact,
        IMPACT_WEIGHTS[:unknown]
      )

      case impact
      when :critical
        reasons << "Impacto operacional classificado como crítico."
      when :high
        reasons << "Ticket possui alto impacto operacional."
      when :medium
        reasons << "Ticket possui impacto operacional moderado."
      end

      weight
    end

    # ---------------------------------------------------------------
    # URGENCY
    # ---------------------------------------------------------------

    def urgency_score(snapshot, reasons)
      urgency = normalize_key(snapshot.ticket.urgency)

      weight = URGENCY_WEIGHTS.fetch(
        urgency,
        URGENCY_WEIGHTS[:unknown]
      )

      case urgency
      when :immediate
        reasons << "Solicitação exige resposta imediata."
      when :high
        reasons << "Urgência informada como alta."
      end

      weight
    end

    # ---------------------------------------------------------------
    # TICKET AGE
    # ---------------------------------------------------------------

    def aging_score(snapshot, reasons)
      hours = snapshot.age_minutes / 60.0

      score =
        case hours
        when 0...4
          0.0
        when 4...12
          1.5
        when 12...24
          3.0
        when 24...48
          5.0
        when 48...72
          7.0
        when 72...168
          9.0
        else
          11.0
        end

      if hours >= 72
        reasons << "Ticket permanece aberto há mais de três dias."
      elsif hours >= 24
        reasons << "Tempo de abertura começa a elevar a prioridade."
      end

      score
    end

    # ---------------------------------------------------------------
    # WAITING TIME
    # ---------------------------------------------------------------

    def waiting_score(snapshot, reasons)
      minutes = snapshot.waiting_minutes
      hours = minutes / 60.0

      score =
        case hours
        when 0...2
          0.0
        when 2...6
          1.0
        when 6...12
          2.0
        when 12...24
          4.0
        when 24...48
          6.0
        else
          8.0
        end

      if hours >= 24
        reasons << "Cliente está esperando interação há mais de 24 horas."
      elsif hours >= 12
        reasons << "Tempo desde a última interação relevante está elevado."
      end

      score
    end

    def waiting_minutes(ticket)
      reference_time =
        ticket.last_agent_response_at ||
        ticket.last_activity_at ||
        ticket.created_at

      minutes_between(reference_time, now)
    end

    # ---------------------------------------------------------------
    # USERS AFFECTED
    # ---------------------------------------------------------------

    def affected_users_score(snapshot, reasons)
      users = snapshot.affected_users

      score =
        case users
        when 0..1
          0.0
        when 2..5
          1.0
        when 6..20
          3.0
        when 21..100
          5.0
        when 101..500
          7.0
        else
          9.0
        end

      if users > 500
        reasons << "Incidente afeta mais de 500 usuários."
      elsif users > 100
        reasons << "Grande quantidade de usuários potencialmente afetada."
      elsif users > 20
        reasons << "Impacto envolve múltiplos usuários."
      end

      score
    end

    # ---------------------------------------------------------------
    # REOPEN COUNT
    # ---------------------------------------------------------------

    def reopen_score(snapshot, reasons)
      count = snapshot.reopen_count

      score =
        case count
        when 0
          0.0
        when 1
          1.5
        when 2
          3.0
        when 3
          4.5
        else
          6.0
        end

      if count >= 3
        reasons << "Ticket foi reaberto repetidamente."
      elsif count.positive?
        reasons << "Ticket já foi reaberto #{count} vez(es)."
      end

      score
    end

    # ---------------------------------------------------------------
    # CUSTOMER TIER
    # ---------------------------------------------------------------

    def customer_score(snapshot, reasons)
      customer = snapshot.ticket.customer
      return 0.0 unless customer

      tier = normalize_key(customer.tier)

      score = CUSTOMER_TIER_WEIGHTS.fetch(tier, 0.0)

      case tier
      when :strategic
        reasons << "Solicitação pertence a cliente estratégico."
      when :enterprise
        reasons << "Solicitação pertence a cliente enterprise."
      end

      score
    end

    # ---------------------------------------------------------------
    # INCIDENT CLUSTERING
    # ---------------------------------------------------------------

    def incident_cluster_score(snapshot, reasons)
      count = snapshot.similar_open_incidents

      score =
        case count
        when 0..1
          0.0
        when 2..3
          2.0
        when 4..7
          4.0
        when 8..15
          6.0
        else
          8.0
        end

      if count >= 8
        reasons << "#{count} tickets abertos aparentam pertencer ao mesmo incidente."
      elsif count >= 4
        reasons << "Há um pequeno agrupamento de incidentes semelhantes."
      end

      score
    end

    def similar_incident_count(ticket)
      fingerprint = ticket.incident_fingerprint

      return 0 if fingerprint.blank?

      Ticket
        .where(team_id: team.id)
        .where(incident_fingerprint: fingerprint)
        .where.not(status: CLOSED_STATUSES)
        .where.not(id: ticket.id)
        .count
    end

    # ---------------------------------------------------------------
    # BLOCKING
    # ---------------------------------------------------------------

    def blocking_score(snapshot, reasons)
      ticket = snapshot.ticket

      score = 0.0

      if ticket.business_process_blocked?
        score += 7.0
        reasons << "Problema bloqueia um processo de negócio."
      end

      if ticket.production_environment?
        score += 4.0
        reasons << "Ocorrência afeta ambiente de produção."
      end

      if ticket.security_related?
        score += 5.0
        reasons << "Ticket possui sinalização relacionada à segurança."
      end

      [score, 10.0].min
    end

    # ---------------------------------------------------------------
    # STARVATION PROTECTION
    # ---------------------------------------------------------------
    #
    # Um dos problemas de filas puramente baseadas em prioridade é que
    # tickets pequenos e de prioridade baixa podem nunca chegar ao topo.
    #
    # Esta regra concede gradualmente pontos adicionais a itens antigos.
    # Assim, um ticket não fica indefinidamente esquecido.
    #
    # ---------------------------------------------------------------

    def starvation_score(snapshot, reasons)
      days = snapshot.age_minutes / 1.day.in_minutes.to_f

      score =
        if days >= 14
          8.0
        elsif days >= 10
          6.0
        elsif days >= 7
          4.0
        elsif days >= 5
          2.0
        else
          0.0
        end

      if score.positive?
        reasons << "Proteção contra starvation aplicada devido à antiguidade do ticket."
      end

      score
    end

    # ---------------------------------------------------------------
    # ASSIGNEE LOAD
    # ---------------------------------------------------------------

    def assignee_overloaded?(snapshot)
      agent = snapshot.current_assignee

      return false unless agent
      return false unless agent.respond_to?(:max_concurrent_tickets)

      limit = safe_integer(
        agent.max_concurrent_tickets,
        10
      )

      snapshot.current_assignee_load[:active_tickets] > limit
    end

    def calculate_agent_load(agent)
      return empty_agent_load unless agent

      active_scope = Ticket
        .where(assignee_id: agent.id)
        .where(status: STATUS_ELIGIBLE_FOR_PRIORITIZATION)

      active_tickets = active_scope.count

      estimated_minutes =
        active_scope
          .where.not(estimated_resolution_minutes: nil)
          .sum(:estimated_resolution_minutes)

      {
        active_tickets: active_tickets,
        estimated_minutes: estimated_minutes.to_i
      }
    end

    def empty_agent_load
      {
        active_tickets: 0,
        estimated_minutes: 0
      }
    end

    # ---------------------------------------------------------------
    # AGENT RECOMMENDATION
    # ---------------------------------------------------------------

    def find_recommended_agent(snapshot, overloaded:)
      ticket = snapshot.ticket

      return nil unless overloaded || snapshot.current_assignee.nil?

      candidates = eligible_agents(ticket)

      ranked_candidates =
        candidates.map do |agent|
          evaluate_agent(
            agent,
            snapshot
          )
        end

      ranked_candidates
        .select { |candidate| candidate.skill_score >= 0.50 }
        .max_by(&:score)
    end

    def eligible_agents(ticket)
      scope =
        Agent
          .where(team_id: team.id)
          .where(active: true)
          .where(available_for_assignment: true)

      if ticket.assignee_id
        scope = scope.where.not(id: ticket.assignee_id)
      end

      scope.includes(:skills).to_a
    end

    def evaluate_agent(agent, snapshot)
      reasons = []

      load = calculate_agent_load(agent)

      skill_score = skill_compatibility(
        snapshot.required_skill_ids,
        agent_skill_ids(agent)
      )

      capacity_score = capacity_score_for(
        agent,
        load
      )

      score = 0.0

      score += skill_score * 55.0
      score += capacity_score * 35.0

      if agent.respond_to?(:on_call?) && agent.on_call?
        score += 5.0
        reasons << "Profissional está no plantão."
      end

      if agent.respond_to?(:accepts_urgent_tickets?) &&
         agent.accepts_urgent_tickets?
        score += 3.0
      end

      if skill_score == 1.0
        reasons << "Possui todas as habilidades necessárias."
      elsif skill_score >= 0.75
        reasons << "Possui alta compatibilidade técnica."
      elsif skill_score >= 0.50
        reasons << "Possui compatibilidade técnica suficiente."
      end

      if capacity_score >= 0.80
        reasons << "Possui boa capacidade operacional disponível."
      end

      AgentCandidate.new(
        agent: agent,
        score: score.round(2),
        skill_score: skill_score.round(2),
        capacity_score: capacity_score.round(2),
        active_ticket_count: load[:active_tickets],
        estimated_workload_minutes: load[:estimated_minutes],
        reasons: reasons
      )
    end

    def skill_compatibility(required_ids, available_ids)
      return 1.0 if required_ids.empty?

      required = required_ids.to_set
      available = available_ids.to_set

      matched = required.intersection(available).size

      matched.to_f / required.size
    end

    def capacity_score_for(agent, load)
      max_tickets =
        if agent.respond_to?(:max_concurrent_tickets)
          safe_integer(agent.max_concurrent_tickets, 10)
        else
          10
        end

      max_minutes =
        if agent.respond_to?(:daily_capacity_minutes)
          safe_integer(agent.daily_capacity_minutes, 420)
        else
          420
        end

      ticket_utilization =
        if max_tickets.zero?
          1.0
        else
          load[:active_tickets].to_f / max_tickets
        end

      minute_utilization =
        if max_minutes.zero?
          1.0
        else
          load[:estimated_minutes].to_f / max_minutes
        end

      utilization = [
        ticket_utilization,
        minute_utilization
      ].max

      clamp(
        1.0 - utilization,
        0.0,
        1.0
      )
    end

    # ---------------------------------------------------------------
    # CONFIDENCE
    # ---------------------------------------------------------------

    def calculate_confidence(snapshot, warnings)
      available_signals = 0
      total_signals = 7

      available_signals += 1 if snapshot.ticket.impact.present?
      available_signals += 1 if snapshot.ticket.urgency.present?
      available_signals += 1 if snapshot.ticket.sla_due_at.present?
      available_signals += 1 if snapshot.ticket.customer.present?
      available_signals += 1 if snapshot.affected_users.positive?
      available_signals += 1 if snapshot.ticket.incident_fingerprint.present?
      available_signals += 1 unless snapshot.required_skill_ids.empty?

      confidence =
        available_signals.to_f / total_signals

      case confidence
      when 0.85..1.0
        :high
      when 0.60...0.85
        :medium
      else
        warnings << "Poucos sinais disponíveis para uma recomendação robusta."
        :low
      end
    end

    # ---------------------------------------------------------------
    # RISK
    # ---------------------------------------------------------------

    def calculate_risk(snapshot, score)
      remaining = snapshot.sla_remaining_minutes

      return :high if remaining && remaining <= 0
      return :high if remaining && remaining <= 30
      return :high if score >= 90

      return :medium if remaining && remaining <= 120
      return :medium if score >= 70

      :low
    end

    # ---------------------------------------------------------------
    # SCORE -> PRIORITY
    # ---------------------------------------------------------------

    def score_to_priority(score)
      if score >= PRIORITY_LEVELS[:critical]
        :critical
      elsif score >= PRIORITY_LEVELS[:high]
        :high
      elsif score >= PRIORITY_LEVELS[:medium]
        :medium
      else
        :low
      end
    end

    # ---------------------------------------------------------------
    # PERSISTENCE
    # ---------------------------------------------------------------

    def persist_result!(ticket, result)
      Ticket.transaction do
        ticket.with_lock do
          previous_score = ticket.priority_score
          previous_priority = ticket.calculated_priority

          ticket.update!(
            priority_score: result.score,
            calculated_priority: result.priority,
            priority_risk: result.risk,
            priority_confidence: result.confidence,
            priority_calculated_at: now,
            recommended_assignee_id: result.recommended_assignee_id
          )

          create_audit_record!(
            ticket: ticket,
            result: result,
            previous_score: previous_score,
            previous_priority: previous_priority
          )
        end
      end
    end

    def create_audit_record!(
      ticket:,
      result:,
      previous_score:,
      previous_priority:
    )
      TicketPriorityAudit.create!(
        ticket_id: ticket.id,
        previous_score: previous_score,
        new_score: result.score,
        previous_priority: previous_priority,
        new_priority: result.priority,
        risk: result.risk,
        confidence: result.confidence,
        recommended_assignee_id: result.recommended_assignee_id,
        reasons: result.reasons,
        warnings: result.warnings,
        scoring_components: result.metadata[:components],
        calculated_at: now
      )
    end

    # ---------------------------------------------------------------
    # FINAL RANKING
    # ---------------------------------------------------------------

    def rank_results(results)
      results.sort_by do |result|
        [
          risk_order(result.risk),
          -result.score,
          result.sla_remaining_minutes || Float::INFINITY,
          result.ticket_id
        ]
      end
    end

    def risk_order(risk)
      {
        high: 0,
        medium: 1,
        low: 2
      }.fetch(risk, 3)
    end

    # ---------------------------------------------------------------
    # ERROR HANDLING
    # ---------------------------------------------------------------

    def report_ticket_error(ticket, error)
      logger.error(
        "[QueuePilot] Failed to prioritize Ticket##{ticket.id}: " \
        "#{error.class} - #{error.message}"
      )

      instrument(
        "queue_pilot.prioritization.error",
        ticket_id: ticket.id,
        error_class: error.class.name,
        message: error.message
      ) {}
    end

    # ---------------------------------------------------------------
    # OBSERVABILITY
    # ---------------------------------------------------------------

    def instrument(event_name, payload = {}, &block)
      ActiveSupport::Notifications.instrument(
        event_name,
        payload,
        &block
      )
    end

    # ---------------------------------------------------------------
    # SUPPORT METHODS
    # ---------------------------------------------------------------

    def required_skill_ids(ticket)
      if ticket.association(:required_skills).loaded?
        ticket.required_skills.map(&:id)
      else
        ticket.required_skills.pluck(:id)
      end
    end

    def agent_skill_ids(agent)
      if agent.association(:skills).loaded?
        agent.skills.map(&:id)
      else
        agent.skills.pluck(:id)
      end
    end

    def normalize_key(value)
      return :unknown if value.blank?

      value
        .to_s
        .strip
        .downcase
        .tr(" ", "_")
        .to_sym
    end

    def safe_integer(value, default)
      Integer(value || default)
    rescue ArgumentError, TypeError
      default
    end

    def minutes_between(start_time, end_time)
      return 0 unless start_time && end_time

      [
        ((end_time - start_time) / 60.0).round,
        0
      ].max
    end

    def clamp(value, minimum, maximum)
      [
        [
          value,
          minimum
        ].max,
        maximum
      ].min
    end
  end
end
