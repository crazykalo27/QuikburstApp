clear; clc; close all;

BASE_DIR = 'C:\Users\kothara1\Quikburst_App\QuikburstApp\AhaanEncoder\ENCODER_TESTING_3_25_2026';  
SETPOINTS_M = [1, 3, 5]; % target positions in metres
SETPOINT_DIRS = {'1m', '3m', '5m'}; % subfolder name for each setpoint
N_TRIALS = 6; % expected trials per setpoint
FINAL_WINDOW_S = 1.0;
TRIAL_COLORS = lines(N_TRIALS);   % 6-row RGB matrix
n_sp = numel(SETPOINTS_M);
trial_data = cell(n_sp, 1);  
final_pos = nan(n_sp, N_TRIALS); % final averaged position (m)
n_actual = zeros(n_sp, 1); % actual number of trials found per setpoint

for i = 1:n_sp
    sp_dir    = fullfile(BASE_DIR, SETPOINT_DIRS{i});
    csv_files = dir(fullfile(sp_dir, '*.csv'));
    n_t            = numel(csv_files);
    n_actual(i)    = n_t;
    trial_data{i}  = cell(n_t, 1);

    for j = 1:n_t
        fpath = fullfile(sp_dir, csv_files(j).name);
        T     = readtable(fpath);
        T.position_m = abs(T.position_m);
        T.velocity_mps = abs(T.velocity_mps);

        required = {'time_s', 'position_m'};
        missing  = required(~ismember(required, T.Properties.VariableNames));
        if ~isempty(missing)
            error('CSV missing column(s) %s in file:\n  %s', ...
                strjoin(missing, ', '), fpath);
        end

        trial_data{i}{j} = T;
        t_end = T.time_s(end);
        mask  = T.time_s >= (t_end - FINAL_WINDOW_S);
        final_pos(i, j) = mean(T.position_m(mask));
    end
end

errors_m = nan(n_sp, N_TRIALS);
for i = 1:n_sp
    n_t = n_actual(i);
    errors_m(i, 1:n_t) = final_pos(i, 1:n_t) - SETPOINTS_M(i);
end
errors_mm = errors_m * 1000;   

%% ═══════════════════════════════════════════════════════════════════════════
%  PLOT 1–3:  Position vs Time, one figure per setpoint
%  Six trial lines converging toward a red dotted setpoint reference
%% ═══════════════════════════════════════════════════════════════════════════

sp_labels = arrayfun(@(x) sprintf('%g m', x), SETPOINTS_M, 'UniformOutput', false);

for i = 1:n_sp
    n_t = n_actual(i);

    figure('Name', sprintf('Pos vs Time  |  Setpoint %s', sp_labels{i}), ...
           'NumberTitle', 'off', 'Units', 'normalized', 'Position', [0.05 0.1 0.55 0.55]);
    hold on; grid on; box on;

    h_trials = gobjects(n_t, 1);
    for j = 1:n_t
        T = trial_data{i}{j};
        h_trials(j) = plot(T.time_s, T.position_m, ...
            'Color',     TRIAL_COLORS(j, :), ...
            'LineWidth', 1.5);
    end

    % Red dotted setpoint reference line
    h_sp = yline(SETPOINTS_M(i), ...
        'Color',       'r', ...
        'LineStyle',   '--', ...
        'LineWidth',   2.0, ...
        'DisplayName', sprintf('Setpoint: %g m', SETPOINTS_M(i)));

    xlabel('Time (s)',     'FontSize', 12);
    ylabel('Position (m)', 'FontSize', 12);

    legend("Trial 1", "Trial 2", "Trial 3", "Trial 4", "Trial 5", "Trial 6", "Setpoint line");

    % Y-axis: start near 0, extend slightly above setpoint
    all_pos = cellfun(@(T) T.position_m, trial_data{i}, 'UniformOutput', false);
    all_pos = vertcat(all_pos{:});
    y_lo    = min(0, min(all_pos) - 0.05);
    y_hi    = max(SETPOINTS_M(i) * 1.10, max(all_pos) + 0.05);
    ylim([y_lo, y_hi]);
end

%% ═══════════════════════════════════════════════════════════════════════════
%  PLOT 4:  Final Position Error vs Setpoint Distance
%  One point per trial per setpoint + mean ± std error bars
%% ═══════════════════════════════════════════════════════════════════════════

figure('Name', 'Final Position Error vs Setpoint Distance', ...
       'NumberTitle', 'off', 'Units', 'normalized', 'Position', [0.1 0.1 0.55 0.5]);
hold on; grid on; box on;

% Small x-jitter so overlapping points are visible
jitter_scale = 0.04;   % metres

for i = 1:n_sp
    n_t = n_actual(i);
    x_jitter = SETPOINTS_M(i) + jitter_scale * (rand(1, n_t) - 0.5);
    scatter(x_jitter, errors_mm(i, 1:n_t), ...
        60, TRIAL_COLORS(1:n_t, :), 'filled', ...
        'MarkerEdgeColor', 'k', 'LineWidth', 0.5, ...
        'HandleVisibility', 'off');
end

% Mean ± std error bars
mean_err_mm = mean(errors_mm, 2, 'omitnan');
std_err_mm  = std( errors_mm, 0, 2, 'omitnan');
errorbar(SETPOINTS_M, mean_err_mm, std_err_mm, ...
    'ko-', 'LineWidth', 2.0, 'MarkerSize', 9, 'CapSize', 10, ...
    'MarkerFaceColor', 'k', ...
    'DisplayName', 'Mean ± Std Dev');

% Zero reference
yline(0, 'k--', 'LineWidth', 1.0, 'HandleVisibility', 'off');

xlabel('Setpoint Distance (m)', 'FontSize', 12);
ylabel('Final Position Error (mm)', 'FontSize', 12);
xticks(SETPOINTS_M);
xticklabels(sp_labels);
xlim([SETPOINTS_M(1) - 0.5, SETPOINTS_M(end) + 0.5]);

% Annotate mean error values above each error bar
for i = 1:n_sp
    text(SETPOINTS_M(i), mean_err_mm(i) + std_err_mm(i) + 0.3, ...
        sprintf('%.2f mm', mean_err_mm(i)), ...
        'HorizontalAlignment', 'center', 'FontSize', 9, 'FontWeight', 'bold');
end

% %% ═══════════════════════════════════════════════════════════════════════════
% %  PLOT 5–7:  Trial # vs Final Position Error, one figure per setpoint
% %% ═══════════════════════════════════════════════════════════════════════════
% 
% for i = 1:n_sp
%     n_t       = n_actual(i);
%     trial_nums = 1:n_t;
%     err_vals   = errors_mm(i, 1:n_t);
%     mean_val   = mean(err_vals, 'omitnan');
% 
%     figure('Name', sprintf('Trial Error  |  Setpoint %s', sp_labels{i}), ...
%            'NumberTitle', 'off', 'Units', 'normalized', 'Position', [0.15 0.1 0.50 0.45]);
%     hold on; grid on; box on;
% 
%     % Bar chart — colour matches the trial colour from Plot 1
%     for j = 1:n_t
%         bar(j, err_vals(j), 0.55, ...
%             'FaceColor', TRIAL_COLORS(j, :), ...
%             'EdgeColor', 'k', 'LineWidth', 0.8, ...
%             'FaceAlpha', 0.75);
%     end
% 
%     % Mean reference line
%     yline(mean_val, 'r--', 'LineWidth', 1.8, ...
%         'DisplayName', sprintf('Mean: %.2f mm', mean_val));
% 
%     % Zero reference
%     yline(0, 'k-', 'LineWidth', 0.8, 'HandleVisibility', 'off');
% 
%     % Annotate each bar with its numeric value
%     y_range = max(abs(err_vals));
%     if y_range == 0; y_range = 1; end
%     offset  = 0.07 * y_range;
%     for j = 1:n_t
%         v = err_vals(j);
%         text(j, v + sign(v + eps) * offset, ...
%             sprintf('%.2f mm', v), ...
%             'HorizontalAlignment', 'center', 'VerticalAlignment', 'bottom', ...
%             'FontSize', 9, 'FontWeight', 'bold');
%     end
% 
%     xlabel('Trial Number', 'FontSize', 12);
%     ylabel('Final Position Error (mm)', 'FontSize', 12);
%     title(sprintf('Trial-to-Trial Error — Setpoint: %g m', SETPOINTS_M(i)), ...
%         'FontSize', 14, 'FontWeight', 'bold');
%     xticks(trial_nums);
%     xlim([0.5, n_t + 0.5]);
%     legend('Location', 'best', 'FontSize', 10);
% end

%% ── CONSOLE SUMMARY ──────────────────────────────────────────────────────────
fprintf('\n%s\n', repmat('=', 1, 62));
fprintf('  ENCODER ACCURACY SUMMARY\n');
fprintf('%s\n', repmat('=', 1, 62));
fprintf('  %-10s  %-13s  %-12s  %-12s\n', ...
    'Setpoint', 'Mean Error', 'Std Dev', 'Max |Error|');
fprintf('  %-10s  %-13s  %-12s  %-12s\n', ...
    '(m)', '(mm)', '(mm)', '(mm)');
fprintf('  %s\n', repmat('-', 1, 55));
for i = 1:n_sp
    e = errors_mm(i, 1:n_actual(i));
    fprintf('  %-10g  %-+13.3f  %-12.3f  %-12.3f\n', ...
        SETPOINTS_M(i), mean(e, 'omitnan'), std(e, 'omitnan'), max(abs(e)));
end
fprintf('%s\n\n', repmat('=', 1, 62));
