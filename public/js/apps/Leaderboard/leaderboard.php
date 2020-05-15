<?php
  define('DB_HOST', 'localhost');
  define('DB_NAME', 'webwork');
  define('DB_USER', 'webworkRead');
  define('DB_PASS', 'passwordRW');

  global $conn;

  $conn = new mysqli(DB_HOST, DB_USER, DB_PASS, DB_NAME);

    if($conn->errno){
        echo "Failed to connect to MySQL database ".$conn->error;
    }

  $user = mysqli_real_escape_string($conn, $_POST['user']);  
  $key = mysqli_real_escape_string($conn, $_POST['key']);
  $thisCourseName = mysqli_real_escape_string($conn, $_POST['courseName']);

  preg_match_all('/([a-zA-Z0-9]*)-([a-zA-Z0-9]*)-([a-zA-Z0-9\-]*)/', $thisCourseName, $courseNameArray);
  $courseCode = $courseNameArray[1][0];
  $semester = $courseNameArray[2][0];
  $thisSectionProf = $courseNameArray[3][0] ?: $thisCourseName;
  $data = [];

  //  MAT1275EN-S18-Parker_achievement_user        
  //  MAT1275EN-S18-Parker_global_user_achievement 
  //  MAT1275EN-S18-Parker_user

  if(validateUser($conn, $user, $key, $thisCourseName) != False){
    http_response_code(200);
    echo leaderboard($conn, $courseCode, $semester, $thisSectionProf);
  }else{
    http_response_code(401);
  }
  
  
  function validateUser($conn, $user, $key, $courseName){
      $query = "SELECT user_id from `".$courseName."_key` WHERE user_id = '".$user."' AND key_not_a_keyword = '".$key."';";
      $result = $conn->query($query);
  
      if(mysqli_num_rows($result) == 0) return null;
  
      return $result;
  }
  
  function leaderboard($conn, $courseCode, $semester, $thisSectionProf) {
    $data = [];
    $query = "SHOW TABLES where tables_in_webwork REGEXP '".$courseCode."-".$semester."-[^_]*_user';";
    $courses = extractRows($conn->query($query), 0);
    if (empty($courses)) {
      $courses[0][0] = $thisSectionProf.'_user';
    }
    foreach($courses as $course){
	$courseName = preg_replace('/_user/','',$course[0]);
        $ours = preg_match('/'.$thisSectionProf.'/',$courseName);
	$data = getCourse($conn, $courseName, $data, $ours);
    }

  return json_encode($data);
  }

  function getCourse($conn, $courseName, $data, $ours){
  
    $query = "SELECT user_id, comment, student_id from `".$courseName."_user` WHERE user_id NOT IN (SELECT user_id from `".$courseName."_permission` WHERE permission > 0);";
  
    // 2D array with only one collumn
    $users = extractRows($conn->query($query), 0);

    $query = "select count(*) from `".$courseName."_problem`;";

    $numOfProblems = extractRows($conn->query($query), 0);

    $query = "select SUM(points) from `".$courseName."_achievement`;";

    $achievementPtsSum = extractRows($conn->query($query), 0);
  
    $achievementsEarned = [];
    $achievementPoints = [];
  
    foreach($users as $user){
      $getEarned = "SELECT COUNT(*) FROM `".$courseName."_achievement_user` WHERE user_id = '$user[0]' AND earned > 0;";
      $getPoints = "SELECT achievement_points FROM `".$courseName."_global_user_achievement` WHERE user_id = '$user[0]';";
  
      array_push($achievementsEarned, extractRows($conn->query($getEarned), 0)[0][0]);
      array_push($achievementPoints, extractRows($conn->query($getPoints), 0)[0][0]);
  
    }
    
    

  
    for($i=0; $i < sizeof($achievementPoints); $i++){
      $data[] = ["id" => $users[$i][0], "username" => $users[$i][1], "uid" => $users[$i][2], "ours" => $ours, "achievementsEarned" => $achievementsEarned[$i], "achievementPoints" => $achievementPoints[$i], "achievementPtsSum" => $achievementPtsSum[0][0], "numOfProblems" => $numOfProblems[0][0]];
    }
  
  
  
    return $data;
  }






  function extractRows($results, $num_or_assoc){
      $rows = array();
      if($num_or_assoc == 0){
          while($row = $results->fetch_array(MYSQLI_NUM) ){
              array_push($rows, $row);
          }

      }else{
          while($row = $results->fetch_array(MYSQLI_ASSOC) ){
              array_push($rows, $row);
          }
      }

      return $rows;

    }

    $conn->close();
