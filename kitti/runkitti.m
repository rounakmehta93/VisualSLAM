function varargout = runkitti(pauseLength, makeVideo)

global Param;
global Data;
global State;

if ~exist('pauseLength','var')
	pauseLength = 0.3; % seconds
end

if makeVideo
	try
		votype = 'avifile';
		vo = avifile('video.avi', 'fps', min(5, 1/pauseLength));
	catch
		votype = 'VideoWriter';
		vo = VideoWriter('video', 'Motion JPEG AVI');
		set(vo, 'FrameRate', min(5, 1/pauseLength));
		open(vo);
	end
end

% ============ %
% Extract Data %
% ============ %

% Sequence base directory
base_dir = './kitti/data/2011_09_26_drive_0018';

% Load oxts data
Data = loadOxtsliteData(base_dir);

% Transform to poses to obitan ground truth.
State.groundTruth = convertOxtsToPose(Data);

l = 0; % coordinate axis length
A = [0 0 0 1; 
	 l 0 0 1; 
	 0 0 0 1; 
	 0 l 0 1; 
	 0 0 0 1; 
	 0 0 l 1]';
figure;
hold on;
axis equal;

% ========================= %
% Parameters Initialization %
% ========================= %

% Initalize Params
Param.initialStateMean = [0; 0; 0];

% Motion Noise
Param.R_mu = 1.0e-03 * [0.2761; -0.0187];
Param.R_Sigma = 1.0e-05 * [0.8660 -0.0038; -0.0038  0.0249];

% TODO: Add measurement noise

% Step size between filter updates (seconds).
Param.deltaT= 0.1;

% Total number of particles to use.
if ~strcmp(Param.slamAlgorithm, 'ekf')
	Param.M = 10;
end

numSteps = length(Data');

% ==================== %
% State Initialization %
% ==================== %
State.Fast.particles = cell(Param.M,1);
for i = 1:Param.M
	State.Fast.particles{i}.x = Param.initialStateMean;
	State.Fast.particles{i}.mu = [];
	State.Fast.particles{i}.Sigma = [];
	State.Fast.particles{i}.weight = 1/Param.M;
	State.Fast.particles{i}.sL = [];
	State.Fast.particles{i}.iL = [];
	State.Fast.particles{i}.nL = 0;
end

for t = 1:numSteps
	% ================= %
	% Plot Ground Truth %
	% ================= %
	B = State.groundTruth{t}*A;
	plotMarker([B(1,1),B(2,1)],'blue');

	% =========== %
	% Filter Info %
	% =========== %
 	u = getControl(t);
	% z = getObservations(t);

	% ========== %
	% Run Filter %
	% ========== %
	fast1_predict_kitti(u,Param.deltaT);
	% fast1_update_kitti(z);

	plotParticles(State.Fast.particles);

	drawnow;
	if pauseLength > 0
		pause(pauseLength);
	end

	if makeVideo
		F = getframe(gcf);
		switch votype
		case 'avifile'
			vo = addframe(vo, F);
		case 'VideoWriter'
			writeVideo(vo, F);
		otherwise
			error('Unrecognized Video Type!');
		end
	end
end

if nargout >= 1
	varargout{1} = Data;
end

end % function

function u = getControl(t)
	global Data;
    temp = Data(t);
	u = [temp{1}(9) temp{1}(10) 1]';
end

function z = getObservations(t)
	global Data;
	% Return Noisy Observations
	% 3xn [range; bearing; markerID];
	z = Data.realObservation(:,:,t);
	ii = find(~isnan(z(1,:)));
	z = z(:,ii);
end
