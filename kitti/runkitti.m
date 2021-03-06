function varargout = runkitti(dataDirectory, pauseLength, makeVideo)

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

if ~exist('dataDirectory','var') || isempty(dataDirectory)
	error('Please specify the base directory of the data.');
end

% ============ %
% Extract Data %
% ============ %

% Load odometry data.
Data.odometry = loadOxtsliteData(dataDirectory);

% Load the images from the left camera.
left_images_path = strcat(dataDirectory, 'image_00/data/');
left_images_filenames = dir(strcat(left_images_path, '*.png'));
Data.leftCameraImages = cell(length(left_images_filenames),1);
for i = 1:length(left_images_filenames)
	left_image_filename = strcat(left_images_path, left_images_filenames(i).name);
	Data.leftCameraImages{i} = imread(left_image_filename);
	Data.leftCameraImages{i} = histeq(Data.leftCameraImages{i});
end

% Load the images from the right camera.
right_images_path = strcat(dataDirectory, 'image_01/data/');
right_images_filenames = dir(strcat(right_images_path, '*.png'));
Data.rightCameraImages = cell(length(right_images_filenames),1);
for i = 1:length(right_images_filenames)
	right_image_filename = strcat(right_images_path, right_images_filenames(i).name);
	Data.rightCameraImages{i} = imread(right_image_filename);
	Data.rightCameraImages{i} = histeq(Data.rightCameraImages{i});
end

if length(left_images_filenames) ~= length(right_images_filenames)
	error('The number of images from the left anf right cameras is unequal.');
end

% Transform to poses to obitan ground truth.
Data.groundTruth = convertOxtsToPose(Data.odometry);

l = 0; % coordinate axis length
A = [0 0 0 1; 
	 l 0 0 1; 
	 0 0 0 1; 
	 0 l 0 1; 
	 0 0 0 1; 
	 0 0 l 1]';
figure(1);
axis equal;

% =================== %
% Initialize Paramers %
% =================== %

calibration_files_path = strcat(dataDirectory, 'calibration/');

% Extract the intrisic and extrinsic parameters of the cameras.
camera_calibration_filename = strcat(calibration_files_path, 'calib_cam_to_cam.txt');
Param.cameraCalibration = loadCalibrationCamToCam(camera_calibration_filename);

% Compute the transformation matrix to go from camera frame to IMU frame.
velodyne_to_camera_calibration_filename = strcat(calibration_files_path, 'calib_velo_to_cam.txt');
imu_to_velodyne_calibration_filename = strcat(calibration_files_path, 'calib_imu_to_velo.txt');

[R_v_to_c, T_v_to_c, H_v_to_c] = loadCalibrationRigid(velodyne_to_camera_calibration_filename);
[R_i_to_v, T_i_to_v, H_i_to_v] = loadCalibrationRigid(imu_to_velodyne_calibration_filename);

Param.R_c_to_i = inv(R_v_to_c*R_i_to_v);
Param.H_c_to_i = inv(H_v_to_c*H_i_to_v);

% Max number of frame to accumulate in the accumulator.
Param.maxAccumulateFrames = 4;

% Max number of SURF descriptors to detect per image.
Param.maxSURFDescriptors = 100;

Param.minDisparity = 15;
Param.maxDisparity = 55;

% Nearest Neighbor Threshold
Param.nnMahalanobisThreshold = 10;
Param.nnEuclideanThreshold = 0.2;

% Initalize Params
Param.initialStateMean = [0; 0; 0];

% Motion Noise
Param.alphas = [0.1, 0.05]; % [m/s,rad/s]
Param.R = diag(Param.alphas.^2);

% Measurement Noise
Param.beta = [2, 2, 4]; % [pixel, pixel, units]
Param.Q = diag(Param.beta.^2);

% Step size between filter updates (seconds).
Param.deltaT= 0.1;

% Total number of particles to use.
if ~strcmp(Param.slamAlgorithm, 'ekf')
	Param.M = 10;
end

Param.maxTimeSteps = length(Data.odometry');

% ==================== %
% State Initialization %
% ==================== %
State.Fast.particles = cell(Param.M,1);
for i = 1:Param.M
	State.Fast.particles{i}.x = Param.initialStateMean;
	State.Fast.particles{i}.mu = [];
	State.Fast.particles{i}.Sigma = [];
	State.Fast.particles{i}.SURF = [];
	State.Fast.particles{i}.weight = 1/Param.M;
	State.Fast.particles{i}.sL = [];
	State.Fast.particles{i}.iL = [];
	State.Fast.particles{i}.nL = 0;
end

errors = zeros(Param.maxTimeSteps, length(Param.initialStateMean));

for t = 1:max(Param.maxTimeSteps,250)
	t
	% ================= %
	% Plot Ground Truth %
	% ================= %
	B = Data.groundTruth{t}*A;
	figure(1); plotMarker([B(1,1),B(2,1)],'blue');

	% =========== %
	% Filter Info %
	% =========== %
	u = getControl(t);
	[points, descriptors] = accumulator(t);
	z = getObservations(t, points, descriptors);

	% ========== %
	% Run Filter %
	% ========== %
	fast1_predict_kitti(u);
	fast1_update_kitti(z);

	samples = zeros(length(Param.initialStateMean), Param.M);
	for k = 1:size(samples,2)
		samples(:,k) = State.Fast.particles{k}.x;
	end
	[mu, Sigma] = meanAndVariance(samples);

	errors(t, :) = mu - [B(1,1); B(2,1); Data.odometry{t}(6)];
	errors(t, 3) = minimizedAngle(errors(t, 3));

	figure(1); plotParticles(State.Fast.particles);

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

steps = 1:Param.maxTimeSteps;
dataSuite = 'KITTI Drive 35';

hold off;
figure;
hold on;
plot(steps, errors(:, 1));
title({dataSuite; '$$\hat{x}$$ - x'}, 'Interpreter', 'Latex');
xlabel('Time Step');
ylabel('Error');

hold off;
figure;
hold on;
plot(steps, errors(:, 2));
title({dataSuite; '$$\hat{y}$$ - y'}, 'Interpreter', 'Latex');
xlabel('Time Step');
ylabel('Error');

if nargout >= 1
	varargout{1} = Data;
end

end % function

function u = getControl(t)
	global Data;
	oxts = Data.odometry(t);
	u = [oxts{1}(9);oxts{1}(23)];
end
