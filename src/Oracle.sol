pragma solidity >=0.6.0;
pragma experimental ABIEncoderV2;

// Import the library implementing the machine template here.
import "./Machine.template.sol";

interface IOracle {

  // questionKey is initialStateHash          
  struct Question {
    uint askTime;
    uint timeout;
    bytes32[] answerKeys;
    function(bytes32, Machine.Image memory) external successCallback;
    function(bytes32) external failCallback;
  }

  // answerKey is imageHash
  struct Answer {
    address answerer;
    bool falsified;
    bytes32 questionKey;
  }

  event NewQuestion (
    bytes32 questionKey,
    Machine.Seed seed,
    address asker
  );

  event NewAnswer (
    bytes32 questionKey,
    bytes32 answerKey
  );

  event AnswerFalsified (
    bytes32 questionKey,
    bytes32 answerKey
  );

  event QuestionResolvedSuccessfully (
    bytes32 questionKey,
    Machine.Image image
  );

  event QuestionResolvedUnsuccessfully (
    bytes32 questionKey
  );

  function getQuestion (
    bytes32 questionKey
  ) external view returns (Question memory);

  function getAnswer (
    bytes32 answerKey
  ) external view returns (Answer memory);

  function ask (
    Machine.Seed calldata seed,
    uint timeout,
    function(bytes32, Machine.Image memory) external successCallback,
    function(bytes32) external failCallback
  ) external;

  function answer (
    bytes32 questionKey,
    bytes32 imageHash
  ) external payable;

  // only Court
  function falsify (
    bytes32 answerKey,
    address prosecutor
  ) external;

  function resolveSuccess (
    bytes32 answerKey,
    Machine.Image calldata image
  ) external;

  function resolveFail (
    bytes32 questionKey
  ) external;
}

abstract contract AOracle is IOracle {
  mapping (bytes32 => Question) public questions;
  mapping (bytes32 => Answer) public answers;

  address public court;
  uint public STAKE_SIZE;
  uint public MAX_ANSWER_NUMBER;

  function getQuestion (
    bytes32 questionKey
  ) override external view returns (Question memory)
  {
    return questions[questionKey];
  }

  function getAnswer (
    bytes32 answerKey
  ) override external view returns (Answer memory)
  {
    return answers[answerKey];
  }

  function ask (
    Machine.Seed calldata seed,
    uint timeout,
    function(bytes32, Machine.Image memory) external successCallback,
    function(bytes32) external failCallback
  ) override external
  {
    bytes32 questionKey = Machine.stateHash(Machine.create(seed));
    Question storage question = questions[questionKey];

    require(!_questionExists(questionKey), "Question already exists.");
    require(timeout > 0, "Timeout must be greater then zero.");

    question.askTime = now;
    question.timeout = timeout;
    question.successCallback = successCallback;
    question.failCallback = failCallback;

    emit NewQuestion(questionKey, seed, msg.sender);
  }

  function answer (
    bytes32 questionKey,
    bytes32 imageHash
  ) override external payable
  {
    Question storage question = questions[questionKey];
    Answer storage answer = answers[imageHash];
    
    require(msg.value >= STAKE_SIZE, "Not enough stake sent.");
    require(_questionExists(questionKey), "Question does not exist.");
    require(!_answerExists(imageHash), "Answer already exists.");
    require(_enoughTimeForAnswer(questionKey), "There is not enoguh time left for submitting new answers to this question.");
    require(question.answerKeys.length < MAX_ANSWER_NUMBER, "All the answer slots are full");

    question.answerKeys.push(imageHash);

    answer.answerer = msg.sender;
    answer.questionKey = questionKey;

    emit NewAnswer(questionKey, imageHash);
  }

  function falsify (
    bytes32 answerKey,
    address prosecutor
  ) override external
  {
    Answer storage answer = answers[answerKey];

    require(_answerExists(answerKey), "The answer trying to be falsified does not exist");
    require(msg.sender == court, "Only court can falsify answers");

    answer.falsified = true;
    payable(prosecutor).call.value(STAKE_SIZE)("");

    emit AnswerFalsified(answer.questionKey, answerKey);
  }

  function resolveSuccess (
    bytes32 answerKey,
    Machine.Image calldata image
  ) override external
  {
    Answer storage answer = answers[answerKey];
    Question storage question = questions[answer.questionKey];

    require(_questionExists(answer.questionKey) && _answerExists(answerKey), "Question and answer must exists.");
    require(now >= question.askTime + question.timeout, "Answering is still in progress.");
    require(Machine.imageHash(image) == answerKey, "Image hash does not match answerKey.");
    require(!answer.falsified, "This answer was falsified");

    bytes32 questionKey = answer.questionKey;
    address answerer = answer.answerer;
    function(bytes32, Machine.Image memory) external callback = question.successCallback;

    _questionCleanup(questionKey);
    payable(answerer).call.value(STAKE_SIZE)("");

    try callback(questionKey, image) {
      emit QuestionResolvedSuccessfully(questionKey, image);
    } catch {
      emit QuestionResolvedUnsuccessfully(questionKey);
    }
  }

  function resolveFail (
    bytes32 questionKey
  ) override external
  {
    Question storage question = questions[questionKey];

    require(_questionExists(questionKey), "Question must exist.");
    require(now >= question.askTime + (2 * question.timeout), "It is not the time to give up yet.");

    function(bytes32) external callback = question.failCallback;

    _questionCleanup(questionKey);
    
    try callback(questionKey) {
      emit QuestionResolvedUnsuccessfully(questionKey);
    } catch {
      emit QuestionResolvedUnsuccessfully(questionKey);
    }
  }

  function _questionCleanup (
    bytes32 questionKey
  ) internal
  {
    for (uint i = 0; i < questions[questionKey].answerKeys.length; i ++) {
      bytes32 answerKey = questions[questionKey].answerKeys[i];
      delete answers[answerKey];
    }
    delete questions[questionKey];
  }

  function _questionExists (
    bytes32 questionKey
  ) internal view returns (bool)
  {
    return questions[questionKey].askTime > 0;
  }

  function _answerExists (
    bytes32 answerKey
  ) internal view returns (bool)
  {
    return answers[answerKey].questionKey > 0;
  }

  function _enoughTimeForAnswer (
    bytes32 questionKey
  ) internal view returns (bool)
  {
    Question storage question = questions[questionKey];
    return now < question.askTime + (question.timeout / 3);
  }
}
