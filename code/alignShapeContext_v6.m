function [P_final,cost_final,out] = alignShapeContext_v6(V2,xpaint,tpaint,meshFileName,normalsFileName,holesFileName,P,imgPainting,OUTDIR)
% This function performs alignment using Shape Context.
%
% Inputs:
% V2pb - Line features for painting (doubles in [0,1])
% V2theta - Line angles for painting (double)
% meshFileName - Mesh file name
% normalsFileName - Normal vectors file name
% holesFileName
% P - Initial camera matrix (from gist retrieval step)
% imgPainting - Painting (uint8, optional, for display purposes)
%
% Outputs:
% P_final - Final camera matrix
% cost_final - Final cost
% out - Structure containing data from each iteration

% Parameters:
Niter = 20; % Maximum number of iterations to run
nsamp1 = 2000;%1000; % Number of Shape Context edge sample points (3D model)
nsamp2 = 2000; % Number of Shape Context edge sample points (painting)
do_display = 0;
Norient = 8; % Number of edge orientations
Niter_ransac = 1000;
inlierThreshPct = 0.005; % Ransac inlier threshold (fraction of image diag)

% Get edge orientation bins:
angBins = linspace(0,pi,Norient+1);

if nargin >= 8
  do_display = 1;
  figure;
  drawnow;
end
if nargin < 9
  OUTDIR = [];
end

imageSize = size(V2);

% Ransac inlier threshold:
inlierThresh = round(inlierThreshPct*sqrt(imageSize(1)^2+imageSize(2)^2));

% Read mesh:
[vertices,faces] = mexReadPly(meshFileName);

% Get binary edge map for painting:
mapPainting = pointsToMap(xpaint(1,:),xpaint(2,:),tpaint,imageSize,Norient);

% Get initial camera parameters and ensure K is in correct form:
[K,R,C] = decomposeP(P);
focal = mean(K([1 5]));
K = [focal 0 K(7); 0 focal K(8); 0 0 1];
Pstart = K*R*[eye(3) -C];

P_previous_iteration = Pstart;
cost_previous_iteration = inf;
out = struct;

% Iteratively align using Shape Context:
for ii = 1:Niter
  display(sprintf('Alignment iteration: %d',ii));

  % Get 3D model features:
  [V1,xmodel,tmodel,isRV,Xdense] = meshFeatures(Pstart,vertices,faces,meshFileName,normalsFileName,holesFileName,imageSize);

  % Get current dense match cost:
  cost_start = matchingCost(Pstart,Xdense,tmodel,mapPainting,inlierThresh);

  display(sprintf('Starting cost: %0.4f',cost_start));
  
% $$$   % Stopping criteria:
% $$$   if cost_previous_iteration <= cost_start
% $$$     display(sprintf('Stopping (previous iteration: %0.4f; current iteration: %0.4f)',cost_previous_iteration,cost_start));
% $$$     cost_start = cost_previous_iteration;
% $$$     Pstart = P_previous_iteration;
% $$$     break;
% $$$   end

  % Sample edges in 3D model (there is randomness in this step):
  n = sampleEdges_v2(xmodel,nsamp1);
  x1 = xmodel(1,n)';
  y1 = xmodel(2,n)';
  t1 = angBins(tmodel(n))';
  X = Xdense(:,n);
  
  % Sample edges in painting:
  n = sampleEdges_v2(xpaint,nsamp2);
  x2 = xpaint(1,n)';
  y2 = xpaint(2,n)';
  t2 = angBins(tpaint(n))';
  
  % Get depth for each point:
  pointDepth = sqrt(sum((X-repmat(C,1,size(X,2))).^2,1));

  % Get points that neighbor each other in model:
  pp = prctile(pointDepth,[10 90]);
  depthRange = (pp(2)-pp(1))/4;
  neighbor3D = (abs(pointDepth'*ones(1,length(pointDepth))-ones(length(pointDepth),1)*pointDepth)<=depthRange);
  
  % Compute Shape Context features:
  mean_dist_global = 0.62*sqrt(imageSize(1)^2+imageSize(2));
  r_inner=1/8;
  r_outer = 0.25;%2;
  nbins_r = 3;%5;
  nbins_theta=12;
% $$$   BH1 = sc_compute_v2([x1 y1]',t1,mean_dist_global,zeros(1,length(x1)),nbins_theta,nbins_r,r_inner,r_outer,[],neighbor3D);
  BH1 = sc_compute_v2([x1 y1]',t1,mean_dist_global,zeros(1,length(x1)),nbins_theta,nbins_r,r_inner,r_outer);
  BH2 = sc_compute_v2([x2 y2]',t2,mean_dist_global,zeros(1,length(x2)),nbins_theta,nbins_r,r_inner,r_outer);

  % Compute shape context match cost:
  ori_weight=0.1;
% $$$   maxDist = 0.2;%0.1;%0.25;
  maxDist = 0.2*(0.5^(ii-1));
  costmat_shape = mex_hist_cost(BH1,BH2);
  theta_diff=repmat(t1,1,length(t2))-repmat(t2',length(t1),1);
  costmat_theta=0.5*(1-cos(2*theta_diff));
  d = sqrt(dist2([x1 y1],[x2 y2]));
  costmat_d = zeros(size(d));
  costmat_d(d>maxDist*sqrt(imageSize(1)^2+imageSize(2)^2)) = inf;
  costmat=(1-ori_weight)*costmat_shape+ori_weight*costmat_theta+costmat_d;

  % Find top nearest neighbors:
  [junk,ns2] = min(costmat,[],2);
  x1_in = x1; y1_in = y1; t1_in = t1;
  x2_in = x2(ns2); y2_in = y2(ns2); t2_in = t2(ns2);

  % Get 2D<->3D correspondences:
  xx = [x2_in y2_in]';

  % Plot sample points and correspondences:
  if do_display
    imgOverlay = overlayEdgeMaps(1-V1,1-V2);

    if isempty(OUTDIR)
      subplot(1,2,1);
    end
    cla;
    imshow(imgOverlay);
    hold on
    title(sprintf('Iteration %d',ii));
    drawnow;
    if ~isempty(OUTDIR)
      print('-djpeg',fullfile(OUTDIR,sprintf('iter_%02d_01_overlay.jpg',ii)));
    end

    % Plot correspondences:
    plot(x1,y1,'b.','MarkerSize',15);
    quiver(x1,y1,cos(t1),sin(t1),0.5,'b')
    plot(x2,y2,'r.','MarkerSize',15);
    quiver(x2,y2,cos(t2),sin(t2),0.5,'r')
    drawnow;
    if ~isempty(OUTDIR)
      print('-djpeg',fullfile(OUTDIR,sprintf('iter_%02d_02_points.jpg',ii)));
    end
    plot([x1_in x2_in]',[y1_in y2_in]','g','LineWidth',2);
    drawnow;
    if ~isempty(OUTDIR)
      print('-djpeg',fullfile(OUTDIR,sprintf('iter_%02d_03_putative.jpg',ii)));
    end
  end

  % Estimate camera parameters via RANSAC:
  NpointsAlg = 3;
  [Pend,cost_ransac] = estimateCamera3d2d_K_ransac_v3(K,X,image2openglcoordinates(xx,imageSize),inlierThresh,NpointsAlg,Xdense,tmodel,mapPainting,Niter_ransac);

  % Get dense set of inliers:
  [nInliers,xPainting] = getDenseInliers(Pend,Xdense,tmodel,mapPainting,inlierThresh);
  
  % Update full camera parameters by minimizing geometric error using
  % dense set of inliers:
  Pend = estimateCamera3d2d_geometric(Pend,Xdense(:,nInliers),image2openglcoordinates(xPainting,imageSize),1);
  
  % Get current matching cost:
  cost_end = matchingCost(Pend,Xdense,tmodel,mapPainting,inlierThresh);
  
  display(sprintf('Start cost: %0.4f; after ransac: %0.4f; after dense: %0.4f',cost_start,cost_ransac,cost_end));

  if cost_end >= cost_start
    cost_end = cost_start;
    Pend = Pstart;
    display(sprintf('Start cost: %0.4f; after ransac: %0.4f; no dense',cost_start,cost_ransac));
  end
  
% $$$   if cost_ransac < cost_start
% $$$     % Get dense set of inliers:
% $$$     [nInliers,xPainting] = getDenseInliers(Pend,Xdense,tmodel,mapPainting,inlierThresh);
% $$$ 
% $$$     % Update full camera parameters by minimizing geometric error using
% $$$     % dense set of inliers:
% $$$     Ptmp = estimateCamera3d2d_geometric(Pend,Xdense(:,nInliers),image2openglcoordinates(xPainting,imageSize),1);
% $$$       
% $$$     % Get current matching cost:
% $$$     cost_end = matchingCost(Ptmp,Xdense,tmodel,mapPainting,inlierThresh);
% $$$ % $$$     cost_end = matchingCost(Pend,Xdense,tmodel,mapPainting,inlierThresh);
% $$$ 
% $$$     display(sprintf('Start cost: %0.4f; after ransac: %0.4f; after dense: %0.4f',cost_start,cost_ransac,cost_end));
% $$$   
% $$$     if cost_end > cost_ransac
% $$$       cost_end = cost_ransac;
% $$$     else
% $$$       Pend = Ptmp;
% $$$     end
% $$$   else
% $$$ % $$$     cost_end = cost_ransac;
% $$$     cost_end = cost_start;
% $$$     Pend = Pstart;
% $$$     display(sprintf('Start cost: %0.4f; after ransac: %0.4f; no dense',cost_start,cost_ransac));
% $$$   end
  
  % Display initial set of inliers
  if do_display
    % Get dense set of inliers:
    [nInliers,xPainting,x3D] = getDenseInliers(Pstart,Xdense,tmodel,mapPainting,inlierThresh);
    if isempty(OUTDIR)
      subplot(1,2,2);
    end
    cla;
    imshow(imgOverlay);
    hold on;
    plot([x3D(1,:); xPainting(1,:)],[x3D(2,:); xPainting(2,:)],'g');
    plot(x3D(1,:),x3D(2,:),'b.','MarkerSize',15);
    plot(xPainting(1,:),xPainting(2,:),'r.','MarkerSize',15);
    title(sprintf('Iteration %d: %d inliers',ii,size(x3D,2)));
    drawnow;
    if ~isempty(OUTDIR)
      print('-djpeg',fullfile(OUTDIR,sprintf('iter_%02d_04_inlier_before_%06d_%0.4f.jpg',ii,size(x3D,2),cost_start)));
    end
  
    % Display updated set of inliers:
    if cost_end < cost_start
      % Get dense set of inliers:
      [nInliers,xPainting] = getDenseInliers(Pend,Xdense,tmodel,mapPainting,inlierThresh);
      x3D = project3D2D(Pstart,Xdense(:,nInliers),imageSize);
      if isempty(OUTDIR)
        subplot(1,2,2);
      end
      cla;
      imshow(imgOverlay);
      hold on;
      plot([x3D(1,:); xPainting(1,:)],[x3D(2,:); xPainting(2,:)],'g');
      plot(x3D(1,:),x3D(2,:),'b.','MarkerSize',15);
      plot(xPainting(1,:),xPainting(2,:),'r.','MarkerSize',15);
      title(sprintf('Iteration %d: %d inliers',ii,size(x3D,2)));
      drawnow;
      if ~isempty(OUTDIR)
        print('-djpeg',fullfile(OUTDIR,sprintf('iter_%02d_05_inlier_after_%06d_%0.4f.jpg',ii,size(x3D,2),cost_end)));
      end
    end
  end

  % Get outputs:
  out(ii).iteration = ii;
  out(ii).edge3D = V1;
  out(ii).edgePainting = V2;
% $$$   out(ii).edge3D = mean(double(lines_all),3)/255;
% $$$   out(ii).edgePainting = 1-(V2pb>edgeThreshPainting);
  out(ii).sc.x3D = [x1 y1]';
  out(ii).sc.xPainting = [x2 y2]';
  out(ii).sc.correspondences = ns2;
  out(ii).Pstart = Pstart;
  out(ii).Pend = Pend;
  out(ii).cost_start = cost_start;
  out(ii).cost_ransac = cost_ransac;
  out(ii).cost_end = cost_end;
  out(ii).inlier.x3D = x3D;
  out(ii).inlier.xPainting = xPainting;
  
  if cost_start < cost_previous_iteration
    P_previous_iteration = Pstart;
    cost_previous_iteration = cost_start;
  end

  % Check for stopping condition:
  if cost_start <= cost_end
    display('Stopping: we did not find better camera parameters this iteration');
    break;
  end

  % Set up for next ieration:
% $$$   P_previous_iteration = Pstart;
% $$$   cost_previous_iteration = cost_start;
  Pstart = Pend;
  [K,R,C] = decomposeP(Pstart);
end

% Get final outputs:
P_final = P_previous_iteration;
cost_final = cost_previous_iteration;
% $$$ P_final = Pstart;
% $$$ cost_final = cost_start;

% $$$ % Plot final alignment:
% $$$ if ~isempty(OUTDIR)
% $$$   lines_all = meshLineDrawing(P_final,meshFileName,normalsFileName,holesFileName,imageSize);
% $$$   imgOverlay = overlayEdgeMaps(mean(double(lines_all),3)/255,1-(V2pb>edgeThreshPainting));
% $$$   cla;
% $$$   imshow(imgOverlay);
% $$$   drawnow;
% $$$   print('-djpeg',fullfile(OUTDIR,sprintf('iter_%02d_01_final_%0.4f.jpg',ii+1,cost_final)));
% $$$ end
